"""PF300718(인생은 오디션 TOP 5 콘서트)에서 "신규 등록" 기능으로 두 아티스트를 등록하려다
둘 다 무관한 기존 아티스트로 잘못 흡수된 걸 되돌리는 일회용 스크립트.

1) "김중연"(신규 등록하려던 사람) -> 로마자 경유 매칭 버그(app/services/artist_matching.py에서
   수정함, 한글끼리도 로마자 비교를 태워서 "중"/"정"처럼 다른 음절이 우연히 비슷해짐)로 완전히
   다른 실존 인물 "김정균"(MusicBrainz mbid 있음, PF297918 주현미 콘서트에 나오는 진짜 트로트
   가수, display_name을 "김중연"으로 잘못 덮어씀)과 합쳐짐. 그 canonical의 display_name
   오버라이드를 되돌리고, 별도의 신규 canonical을 만들어 이 콘서트만 옮긴다.
2) "JAEHA"(신규 등록하려던 사람) -> 이미 존재하는 다른 실존 아티스트(표시명 "재하",
   MusicBrainz 연동됨)와 표기가 정확히 똑같아서(동명이인, 로마자 버그와는 무관) 그쪽으로
   합쳐짐. 사용자 확인 결과 다른 사람이라, 그 별칭 등록을 지우고 별도 신규 canonical을 만든다.
   (canonical_name이 똑같은 두 canonical이 공존하는 건 스키마상 허용됨 - unique 제약은 mbid에만
   있음. 동명이인은 이 시스템이 원래 문자열만으로 원리적으로 못 푸는 부분이라 별개 canonical로
   분리하는 것 이상은 하지 않음)

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/fix_pf300718_namesake_and_romanization_bugs.py
"""

import asyncio
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import delete, func, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import ArtistAlias, CanonicalArtist  # noqa: E402
from app.models.concert import Concert  # noqa: E402

_KIM_JUNG_GYUN_WRONG_DISPLAY_NAME = "김중연"
_NEW_KIM_JUNG_YEON = "김중연"
_JAEHA_TEXT = "JAEHA"


async def main() -> None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == "PF300718"))
        concert = result.scalar_one_or_none()
        if concert is None:
            print("PF300718을 찾을 수 없음")
            return
        names = list(concert.artist_name or [])
        print(f"수정 전 artist_name: {names}")

        # --- 1) 김정균/김중연 ---
        kim_result = await db.execute(
            select(CanonicalArtist).where(CanonicalArtist.canonical_name == "김정균")
        )
        kim_canonical = kim_result.scalar_one_or_none()
        if kim_canonical is None:
            print("canonical '김정균'을 찾을 수 없음 - 1)단계 건너뜀")
        else:
            print(f"김정균 canonical: id={kim_canonical.id} display_name={kim_canonical.display_name!r}")
            if kim_canonical.display_name == _KIM_JUNG_GYUN_WRONG_DISPLAY_NAME:
                kim_canonical.display_name = None
                print("  -> display_name 오버라이드 제거(원래 진짜 이름 '김정균'으로 복구)")

            deleted = await db.execute(
                delete(ArtistAlias).where(
                    ArtistAlias.canonical_artist_id == kim_canonical.id,
                    func.lower(ArtistAlias.alias_text) == "김중연",
                )
            )
            print(f"  -> 잘못 등록된 별칭 '김중연' {deleted.rowcount}건 삭제")

            new_kim = CanonicalArtist(mbid=None, canonical_name=_NEW_KIM_JUNG_YEON)
            db.add(new_kim)
            await db.flush()
            db.add(ArtistAlias(canonical_artist_id=new_kim.id, alias_text=_NEW_KIM_JUNG_YEON, source="admin_reassign"))
            print(f"  -> 신규 canonical '{_NEW_KIM_JUNG_YEON}' 생성(id={new_kim.id})")

            if "김정균" in names:
                names = [_NEW_KIM_JUNG_YEON if n == "김정균" else n for n in names]
                print("  -> 이 콘서트의 artist_name에서 '김정균' -> '김중연'로 교체(이 콘서트만, PF297918은 안 건드림)")

        # --- 2) JAEHA(동명이인) ---
        jaeha_result = await db.execute(
            select(CanonicalArtist).where(CanonicalArtist.canonical_name == "JAEHA")
        )
        jaeha_canonicals = jaeha_result.scalars().all()
        # admin_reassign 소스로 등록된 잘못된 별칭이 걸린 canonical만 대상(정말 "재하" 본인 것은 그대로 둠)
        for existing in jaeha_canonicals:
            deleted = await db.execute(
                delete(ArtistAlias).where(
                    ArtistAlias.canonical_artist_id == existing.id,
                    func.lower(ArtistAlias.alias_text) == "jaeha",
                    ArtistAlias.source == "admin_reassign",
                )
            )
            if deleted.rowcount:
                print(f"JAEHA: canonical {existing.id}({existing.display_name or existing.canonical_name})의 admin_reassign 별칭 {deleted.rowcount}건 삭제")

        new_jaeha = CanonicalArtist(mbid=None, canonical_name=_JAEHA_TEXT)
        db.add(new_jaeha)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=new_jaeha.id, alias_text=_JAEHA_TEXT, source="admin_reassign"))
        print(f"JAEHA: 신규(별개 인물) canonical 생성(id={new_jaeha.id}) - artist_name 텍스트 자체는 변경 없음")

        concert.artist_name = sorted(set(names))
        await db.commit()
        await db.refresh(concert)
        print(f"\n수정 후 artist_name: {concert.artist_name}")


if __name__ == "__main__":
    asyncio.run(main())
