import pytest

from app.core.database import AsyncSessionLocal
from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.services.headliner import load_name_variants, pick_headliners


def _variants(*names: str) -> list[set[str]]:
    return [{n} for n in names]


def test_title_with_one_artist_name_picks_that_artist():
    assert pick_headliners("유승우 단독 공연: 청춘의 단상", _variants("유승우", "최준의 단상")) == {0}


def test_no_artist_in_title_is_undecided():
    assert pick_headliners("라라라온 [롤링홀]", _variants("삵", "이혁정모")) is None


def test_all_artists_in_title_returns_everyone():
    assert pick_headliners("소향 X 김기태 THE GREATEST", _variants("소향", "김기태")) == {0, 1}


def test_guest_marker_excludes_names_after_it():
    assert pick_headliners("송창식 with friends: 안예은", _variants("송창식", "안예은")) == {0}
    assert pick_headliners("김솔아 콰르텟 (Guest 이진아)", _variants("김솔아", "이진아")) == {0}


def test_alias_matches_other_language_title():
    variants = [{"포스트 말론", "Post Malone"}, {"Don Toliver"}]
    assert pick_headliners("Post Malone Live in Seoul", variants) == {0}


def test_single_character_names_are_ignored():
    # 한 글자 이름은 공연명에 우연히 들어가기 쉬워서 판정에 안 씀
    assert pick_headliners("A Night of Music", _variants("A", "B")) is None


@pytest.mark.asyncio
async def test_load_name_variants_includes_canonical_and_aliases():
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=None, canonical_name="Headliner Canonical Test", display_name="헤드라이너표시명")
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text="헤드라이너별칭테스트", source="musicbrainz"))
        await db.commit()

        variants = await load_name_variants(db, None, ["헤드라이너별칭테스트", "매칭안되는가수"])

    assert {"헤드라이너별칭테스트", "Headliner Canonical Test", "헤드라이너표시명"} <= variants[0]
    assert variants[1] == {"매칭안되는가수"}
