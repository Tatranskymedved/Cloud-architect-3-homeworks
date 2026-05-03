import io

from fastapi import FastAPI, Request, HTTPException, Response
from PIL import Image

app = FastAPI()


@app.post("/thumbnail")
async def thumbnail(request: Request):
    body = await request.body()
    if not body:
        raise HTTPException(status_code=400, detail="Empty body")
    try:
        img = Image.open(io.BytesIO(body))
        img.thumbnail((128, 128))
        buf = io.BytesIO()
        fmt = img.format or "JPEG"
        img.save(buf, format=fmt)
        return Response(
            content=buf.getvalue(),
            media_type="image/jpeg" if fmt == "JPEG" else "image/png",
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=422, detail=str(e))
