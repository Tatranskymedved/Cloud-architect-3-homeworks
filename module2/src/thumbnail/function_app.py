import io

import azure.functions as func
from PIL import Image

app = func.FunctionApp()


@app.route(route="thumbnail", methods=["POST"])
def thumbnail(req: func.HttpRequest) -> func.HttpResponse:
    body = req.get_body()
    if not body:
        return func.HttpResponse("Empty body", status_code=400)
    try:
        img = Image.open(io.BytesIO(body))
        img.thumbnail((128, 128))
        buf = io.BytesIO()
        fmt = img.format or "JPEG"
        img.save(buf, format=fmt)
        return func.HttpResponse(
            body=buf.getvalue(),
            mimetype="image/jpeg" if fmt == "JPEG" else "image/png",
            status_code=200,
        )
    except Exception as e:
        return func.HttpResponse(str(e), status_code=422)
