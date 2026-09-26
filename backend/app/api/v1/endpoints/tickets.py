from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user, rate_limit_diary_generation, verify_llm_api_key
from app.models.ticket import Ticket
from app.models.user import User
from app.schemas.artist_identity import (
    IdentityCandidatesResponse, IdentityChangeRequest, IdentityChangeResponse,
)
from app.schemas.diary import DiaryResultRequest, DiaryResultResponse
from app.schemas.setlist import (
    RealSetlistResponse, PreSetlistResponse, SetlistFmCandidate,
    SetlistEditRequest, FetchSetlistRequest, ArtistAnchorCandidate, ArtistAnchorRequest, ArtistCandidate,
)
from app.schemas.ticket import TicketCreate, TicketListItem, TicketUpdate, TicketWithConcert
from app.services.artist_identity import (
    attach_artist_display_names,
    canonical_summary,
    change_concert_artist_identity,
    identity_candidates,
)
from app.services.crawler import crawl_and_save
from app.services.lastfm import ensure_artist_genres_cached
from app.services.llm_batch_state import mark_llm_callback_received, try_stop_pod_if_done
from app.services.pre_setlist import (
    apply_itunes_anchor,
    check_pre_setlist_on_view,
    get_pre_setlist,
    generate_pre_setlist,
    generate_pre_setlist_background,
    refresh_setlists_after_identity_change,
    regenerate_pre_setlists_for_artist,
    search_anchor_artist_candidates,
    update_pre_setlist,
)
from app.services.representative_songs import search_itunes_songs
from app.services.setlist import (
    get_real_setlist,
    search_setlists_for_concert,
    fetch_and_save_real_setlist,
    generate_real_setlist_auto,
    check_real_setlist_on_view,
    update_real_setlist,
)
from app.services.ticket import (
    create_ticket,
    get_sorted_tickets,
    get_ticket,
    request_ticket_diary,
    update_ticket,
    delete_ticket,
)

router = APIRouter()


# 티켓 등록
@router.post("", response_model=TicketWithConcert, status_code=status.HTTP_201_CREATED)
async def register_ticket(
    body: TicketCreate,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await create_ticket(db, current_user, body)
    if ticket.ticketing_site:
        background_tasks.add_task(crawl_and_save, ticket.concert_id, ticket.ticketing_site)
    if ticket.concert and ticket.concert.artist_name:
        # 아티스트 정보가 있으니 예상 셋리스트도 바로 생성 시도(Setlist.fm에 데이터가
        # 없으면 generate_pre_setlist_background 내부에서 조용히 스킵됨). 이미 생성된
        # 적 있으면 generate_pre_setlist가 upsert하므로 여러 유저가 같은 공연에
        # 티켓을 등록해도 안전함.
        background_tasks.add_task(generate_pre_setlist_background, ticket.concert.id)
        # 결산 "선호 장르"에 쓰일 아티스트가 이번에 처음 확정됐으니, 야간 배치를 기다리지 않고
        # 바로 캐싱(이미 캐싱된 아티스트면 ensure_artist_genres_cached 내부에서 스킵됨)
        background_tasks.add_task(ensure_artist_genres_cached, ticket.concert.artist_name)
    await attach_artist_display_names(db, [ticket.concert])
    return ticket



# 내 티켓 목록 조회 (limit/offset은 선택 - 생략하면 기본 상한(200건) 적용)
@router.get("", response_model=list[TicketListItem])
async def list_tickets(
    limit: int = Query(200, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    tickets = await get_sorted_tickets(db, current_user.id, limit=limit, offset=offset)
    await attach_artist_display_names(db, [t.concert for t in tickets])
    return tickets


# 티켓 상세 조회
@router.get("/{ticket_id}", response_model=TicketWithConcert)
async def retrieve_ticket(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    await attach_artist_display_names(db, [ticket.concert])
    return ticket


# 티켓 수정
@router.patch("/{ticket_id}", response_model=TicketWithConcert)
async def modify_ticket(
    ticket_id: UUID,
    body: TicketUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await update_ticket(db, current_user, ticket_id, body)
    await attach_artist_display_names(db, [ticket.concert])
    return ticket


# 티켓 -> (concert_id, 관람일) 추출. 관람일이 없고 공연이 여러 날짜에 걸치면 아래 setlist
# 서비스 함수들이 400으로 날짜 지정을 요구함(추측해서 엉뚱한 날짜의 셋리스트를 주지 않기 위함)
def _ticket_concert_and_date(ticket: Ticket):
    if ticket.concert_id is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    explicit_date = ticket.attended_date.date() if ticket.attended_date else None
    return ticket.concert_id, explicit_date


# 티켓 기준 실제 셋리스트 조회 (내부적으로 ticket.concert_id + attended_date로 위임).
# 결과가 비어있으면(자동 백필 14일 창을 놓친 경우 등) 화면은 그대로 빈 상태로 응답하고,
# 백그라운드로 한 번 더 채워보기를 시도함(check_real_setlist_on_view - 콘서트+날짜 단위
# 하루 쿨다운). 응답을 기다리게 하지 않으므로, 채워지더라도 이번 조회엔 안 보이고 다음에
# 다시 열어야 반영됨.
@router.get("/{ticket_id}/setlist", response_model=RealSetlistResponse)
async def get_ticket_real_setlist(
    ticket_id: UUID,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    result = await get_real_setlist(db, concert_id, explicit_date)
    songs = result["songs"] if isinstance(result, dict) else result.songs
    if not songs:
        performance_date = result["performance_date"] if isinstance(result, dict) else result.performance_date
        background_tasks.add_task(check_real_setlist_on_view, concert_id, performance_date)
    return result


# 티켓 기준 Setlist.fm 후보 검색
@router.get("/{ticket_id}/setlist/search", response_model=list[SetlistFmCandidate])
async def search_ticket_real_setlists(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    return await search_setlists_for_concert(db, concert_id, explicit_date)


# 티켓 기준으로 Setlist.fm ID의 셋리스트를 가져와 저장
@router.post("/{ticket_id}/setlist", response_model=RealSetlistResponse, status_code=status.HTTP_201_CREATED)
async def fetch_ticket_real_setlist(
    ticket_id: UUID,
    body: FetchSetlistRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    return await fetch_and_save_real_setlist(db, concert_id, body.setlistfm_id, explicit_date)


# 티켓 기준 실제 셋리스트 유저 수정
@router.patch("/{ticket_id}/setlist", response_model=RealSetlistResponse)
async def edit_ticket_real_setlist(
    ticket_id: UUID,
    body: SetlistEditRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    return await update_real_setlist(db, concert_id, body.songs, current_user.nickname, explicit_date)


# 아티스트별 자동 검색+병합으로 실제 셋리스트 생성(페스티벌뿐 아니라 단독 공연도 동작).
# 위 search+POST(단독 후보 선택) 흐름과 별개 - 프론트에 다중 선택 UI가 아직 없어도
# 바로 쓸 수 있는 자동 경로. 자세한 배경은 generate_real_setlist_auto 참고.
@router.post(
    "/{ticket_id}/setlist/generate-festival",
    response_model=RealSetlistResponse,
    status_code=status.HTTP_201_CREATED,
)
async def generate_ticket_real_setlist_auto(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    return await generate_real_setlist_auto(db, concert_id, explicit_date)


# show_predicted_setlist는 이제 조회 자체를 막는 스위치가 아니라 프론트 블러
# 처리용 화면 취향 값이라(꺼도 데이터는 그대로 내려줘야 롱탭/홀드로 잠깐
# 풀어볼 수 있는 기능을 만들 수 있음), 아래 세 엔드포인트에서 하던 403
# 게이팅을 제거함. 값 자체(GET/PATCH /settings)는 그대로 유지.


# 예상 셋리스트는 아티스트 과거 통계 기반 추측이라 곡 자체는 날짜에 안 묶이지만, 페스티벌처럼
# 아티스트가 여럿이면 ticket.attended_date에 배정된 아티스트로 좁혀서 보여줌(get_pre_setlist
# 참고) - 배정 정보가 없으면 기존처럼 전체 반환
@router.get("/{ticket_id}/setlist/pre", response_model=PreSetlistResponse)
async def get_ticket_pre_setlist(
    ticket_id: UUID,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    result = await get_pre_setlist(db, concert_id, explicit_date)
    # 비어 있으면 백그라운드로 한 번 더 생성(check_pre_setlist_on_view) - 앱이 짧게 재확인함
    songs = result["songs"] if isinstance(result, dict) else result.songs
    if not songs:
        background_tasks.add_task(check_pre_setlist_on_view, concert_id)
    return result


@router.post("/{ticket_id}/setlist/pre/generate", response_model=PreSetlistResponse, status_code=status.HTTP_201_CREATED)
async def generate_ticket_pre_setlist(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, _ = _ticket_concert_and_date(ticket)
    return await generate_pre_setlist(db, concert_id)


@router.patch("/{ticket_id}/setlist/pre", response_model=PreSetlistResponse)
async def edit_ticket_pre_setlist(
    ticket_id: UUID,
    body: SetlistEditRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, _ = _ticket_concert_and_date(ticket)
    return await update_pre_setlist(db, concert_id, body.songs, current_user.nickname)


# 예상 셋리가 빈 아티스트를 공연 아티스트 이름으로 찾은 후보(iTunes) - 유저가 이 중에서 골라 확정
@router.get("/{ticket_id}/setlist/pre/artist-candidates", response_model=list[ArtistCandidate])
async def search_ticket_artist_candidates(
    ticket_id: UUID,
    artist: str = Query(..., min_length=1),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, _ = _ticket_concert_and_date(ticket)
    return await search_anchor_artist_candidates(db, concert_id, artist)


# 후보에 원하는 아티스트가 없을 때의 대안 - 곡 제목으로 검색(iTunes)해 고른 곡의 아티스트로 확정
@router.get("/{ticket_id}/setlist/pre/anchor-candidates", response_model=list[ArtistAnchorCandidate])
async def search_ticket_anchor_candidates(
    ticket_id: UUID,
    song: str = Query(..., min_length=1),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await get_ticket(db, current_user.id, ticket_id)
    return await search_itunes_songs(song)


# 고른 iTunes 아티스트로 확정 후 이 공연 예상 셋리를 대표곡으로 다시 채워 반환, 같은 아티스트의
# 다른 예정 공연은 백그라운드로 재생성
@router.post("/{ticket_id}/setlist/pre/anchor", response_model=PreSetlistResponse)
async def anchor_ticket_pre_setlist_artist(
    ticket_id: UUID,
    body: ArtistAnchorRequest,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    result = await apply_itunes_anchor(db, concert_id, body.artist, body.itunes_artist_id, explicit_date)
    background_tasks.add_task(regenerate_pre_setlists_for_artist, body.artist, concert_id)
    return result


# 이 공연의 아티스트가 다른 사람으로 잘못 연결됐을 때 - 우리 DB/MusicBrainz 후보
@router.get("/{ticket_id}/artist-identity/candidates", response_model=IdentityCandidatesResponse)
async def get_ticket_artist_identity_candidates(
    ticket_id: UUID,
    artist: str = Query(..., min_length=1),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, _ = _ticket_concert_and_date(ticket)
    return await identity_candidates(db, concert_id, artist)


# 이 공연에서만 아티스트 연결을 바로 바꾸고(기록은 관리자 페이지에서 되돌릴 수 있음), 예상/실제
# 셋리를 새 연결 기준으로 다시 채운 뒤 응답 - 앱이 바로 다시 불러와서 보여주므로 기다림(앵커와 같음)
@router.post("/{ticket_id}/artist-identity", response_model=IdentityChangeResponse)
async def change_ticket_artist_identity(
    ticket_id: UUID,
    body: IdentityChangeRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, _ = _ticket_concert_and_date(ticket)
    target = await change_concert_artist_identity(
        db, concert_id, body.artist,
        canonical_id=body.canonical_id, mbid=body.mbid, no_artist=body.no_artist,
        user_id=current_user.id, source="user",
    )
    await refresh_setlists_after_identity_change(concert_id)
    return {"artist": body.artist, "current": canonical_summary(target), "no_artist": target is None}


# 한줄평 기반 공연 일기 생성 요청 (diary_requested_at만 찍어두고 즉시 반환 - 실제 LLM팀 전송은
# 자정 배치가 처리하므로, 클라이언트는 GET /tickets/{id}를 폴링해 diary가 채워지는 걸 확인해야 함)
@router.post("/{ticket_id}/diary", response_model=TicketWithConcert, status_code=status.HTTP_202_ACCEPTED)
async def create_ticket_diary(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    _rate_limit: None = Depends(rate_limit_diary_generation),
):
    return await request_ticket_diary(db, current_user.id, ticket_id)


# LLM팀이 자정 배치로 처리한 공연 일기 결과를 전송하는 웹훅 엔드포인트
@router.post("/{ticket_id}/diary-result", response_model=DiaryResultResponse)
async def receive_diary_result(
    ticket_id: UUID,
    body: DiaryResultRequest,
    background_tasks: BackgroundTasks,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_llm_api_key),
):
    result = await db.execute(select(Ticket).where(Ticket.id == ticket_id))
    ticket = result.scalar_one_or_none()
    if ticket is None:
        raise HTTPException(status_code=404, detail="티켓을 찾을 수 없습니다.")

    # pod 조기 정지 판단용 갱신 - pod이 살아서 실제로 처리 중이라는 증거. 이 콜백으로 그날 밤
    # 보낸 만큼 다 받았으면(정확한 건수 매칭) 응답 지연 없이 백그라운드로 즉시 pod 정지 시도
    await mark_llm_callback_received()
    background_tasks.add_task(try_stop_pod_if_done)

    ticket.diary = body.diary
    await db.commit()
    return DiaryResultResponse(diary=ticket.diary)


# 티켓 삭제
@router.delete("/{ticket_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_ticket(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await delete_ticket(db, current_user.id, ticket_id)
