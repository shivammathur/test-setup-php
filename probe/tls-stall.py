import os
import socket
import time
from pathlib import Path

with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen(4)
    Path(os.environ["RUNNER_TEMP"], "tls-stall-port").write_text(str(server.getsockname()[1]))
    while True:
        connection, _ = server.accept()
        with connection:
            time.sleep(15)
