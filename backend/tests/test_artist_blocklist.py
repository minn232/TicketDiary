from app.services.artist_blocklist import is_blocklisted_artist_name
from app.services.artist_matching import normalize_artist_names


def test_exact_match_blocked():
    assert is_blocklisted_artist_name("NOL") is True


def test_whitespace_and_case_variants_blocked():
    assert is_blocklisted_artist_name("  nol  ") is True
    assert is_blocklisted_artist_name("Various   Artists") is True


def test_real_artist_name_not_blocked():
    assert is_blocklisted_artist_name("10cm") is False


def test_substring_of_blocklisted_name_not_blocked():
    # exact match만 하므로 블록리스트 문자열을 부분 포함하는 실제 아티스트명은 안 걸림
    assert is_blocklisted_artist_name("NOLGAE") is False


def test_normalize_artist_names_filters_blocklisted_entries():
    result = normalize_artist_names(["NOL", "진짜아티스트", "Various Artists"])
    assert result == ["진짜아티스트"]


def test_normalize_artist_names_blocklisted_name_not_added_to_known_names():
    known: set[str] = set()
    normalize_artist_names(["KIMCHIKURA"], known)
    assert known == set()
