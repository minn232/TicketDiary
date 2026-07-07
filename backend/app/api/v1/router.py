from fastapi import APIRouter

from app.api.v1.endpoints import auth, concerts, tickets, setlists, timetables, summary, notifications, social, settings, upload, venue_layout, crawl

api_router = APIRouter()

api_router.include_router(auth.router, prefix="/auth", tags=["auth"])
api_router.include_router(concerts.router, prefix="/concerts", tags=["concerts"])
api_router.include_router(tickets.router, prefix="/tickets", tags=["tickets"])
api_router.include_router(setlists.router, prefix="/concerts", tags=["setlists"])
api_router.include_router(timetables.router, prefix="/concerts", tags=["timetables"])
api_router.include_router(venue_layout.router, prefix="/concerts", tags=["venue_layout"])
api_router.include_router(crawl.router, prefix="/concerts", tags=["crawl"])
api_router.include_router(summary.router, prefix="/summary", tags=["summary"])
api_router.include_router(notifications.router, prefix="/notifications", tags=["notifications"])
api_router.include_router(social.router, prefix="/social", tags=["social"])
api_router.include_router(settings.router, prefix="/settings", tags=["settings"])
api_router.include_router(upload.router, prefix="/upload", tags=["upload"])