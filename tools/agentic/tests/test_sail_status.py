import datetime as dt
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sail_status import age_str, fmt_ts, _delta_str


def test_age_str_seconds():
    ts = (dt.datetime.now(dt.UTC) - dt.timedelta(seconds=30)).isoformat()
    assert age_str(ts) == "30s ago"


def test_age_str_minutes():
    ts = (dt.datetime.now(dt.UTC) - dt.timedelta(minutes=5)).isoformat()
    assert age_str(ts) == "5m ago"


def test_age_str_hours():
    ts = (dt.datetime.now(dt.UTC) - dt.timedelta(hours=3)).isoformat()
    assert age_str(ts) == "3h ago"


def test_age_str_days():
    ts = (dt.datetime.now(dt.UTC) - dt.timedelta(days=2)).isoformat()
    assert age_str(ts) == "2d ago"


def test_age_str_none():
    assert age_str(None) == "unknown"


def test_age_str_malformed():
    result = age_str("not-a-timestamp")
    assert result == "not-a-timestamp" or result == "unknown"


def test_age_str_future():
    ts = (dt.datetime.now(dt.UTC) + dt.timedelta(seconds=60)).isoformat()
    assert age_str(ts) == "in the future"


def test_fmt_ts_none():
    assert fmt_ts(None) == "—"


def test_delta_str_sub_hour():
    delta = dt.timedelta(minutes=10)
    assert "10m" in _delta_str(delta)
