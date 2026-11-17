"""pyapp: a small WSGI app for the tando python recipe, served by waitress (pure Python).

GET /health -> 200; GET / -> "python v<VERSION> greeting=<GREETING>".
"""
import os

from waitress import serve

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "VERSION")) as f:
    VERSION = f.read().strip()


def app(environ, start_response):
    if environ.get("PATH_INFO") == "/health":
        body = b"ok\n"
    else:
        body = f"python v{VERSION} greeting={os.environ.get('GREETING', '')}\n".encode()
    start_response("200 OK", [("Content-Type", "text/plain"), ("Content-Length", str(len(body)))])
    return [body]


if __name__ == "__main__":
    serve(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8000")))
