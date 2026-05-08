from fastapi import APIRouter
from app.api.v1.endpoints import auth, concerts

api_router = APIRouter()

api_router.include_router(auth.router, prefix="/auth", tags=["auth"])
api_router.include_router(concerts.router, prefix="/concerts", tags=["concerts"])