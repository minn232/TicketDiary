"""Network/database-free checks: python -m unittest discover -s tests -p test_summary_regions_unit.py"""
import unittest
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import httpx

from app.services import summary_regions as regions


class RegionalSummaryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        regions._cache.clear()

    async def test_exact_facility_coordinates_and_cache(self):
        calls = []
        def respond(request):
            calls.append(request.url.path)
            xml = '<dbs><db><mt10id>FC1</mt10id></db></dbs>' if 'pblprfr' in request.url.path else '<dbs><db><la>37.5209</la><lo>127.1273</lo></db></dbs>'
            return httpx.Response(200, text=xml)
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            with patch.object(regions.settings, 'KOPIS_API_KEY', 'test'), patch.object(regions, '_throttle_kopis_request', AsyncMock()):
                first = await regions._coordinates(client, 'PF1')
                second = await regions._coordinates(client, 'PF1')
        self.assertEqual(first, (37.5209, 127.1273))
        self.assertEqual(first, second)
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[1].endswith('/prfplc/FC1'))

    async def test_missing_facility_does_not_guess_from_venue_name(self):
        async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, text='<dbs><db><fcltynm>문화회관</fcltynm></db></dbs>'))) as client:
            with patch.object(regions.settings, 'KOPIS_API_KEY', 'test'), patch.object(regions, '_throttle_kopis_request', AsyncMock()):
                self.assertIsNone(await regions._coordinates(client, 'PF2'))

    async def test_unavailable_provider_is_unresolved(self):
        async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(503))) as client:
            with patch.object(regions.settings, 'KOPIS_API_KEY', 'test'), patch.object(regions, '_throttle_kopis_request', AsyncMock()):
                self.assertIsNone(await regions._coordinates(client, 'PF3'))

    async def test_attendance_count_and_unknown_locations(self):
        result = MagicMock()
        result.scalars.return_value.all.return_value = ['PF1', 'PF1', None, 'PF2']
        db = AsyncMock()
        db.execute.return_value = result
        async def locate(client, code):
            return (37.5209, 127.1273) if code == 'PF1' else None
        with patch.object(regions, '_coordinates', side_effect=locate):
            summary = await regions.get_regional_summary(db, uuid4(), '6m')
        self.assertEqual(summary['concert_count'], 4)
        self.assertEqual(summary['unresolved_count'], 2)
        self.assertEqual(summary['locations'], [{'latitude': 37.5209, 'longitude': 127.1273, 'count': 2}])
        self.assertIn('coalesce(tickets.attended_date, concerts.start_date)', str(db.execute.call_args.args[0]))

    async def test_empty_history(self):
        result = MagicMock()
        result.scalars.return_value.all.return_value = []
        db = AsyncMock()
        db.execute.return_value = result
        with patch.object(regions, '_coordinates', AsyncMock()) as locate:
            summary = await regions.get_regional_summary(db, uuid4(), 'all')
            locate.assert_not_called()
        self.assertEqual(summary['concert_count'], 0)
        self.assertEqual(summary['locations'], [])
