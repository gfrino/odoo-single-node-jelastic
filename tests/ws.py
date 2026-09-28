import socket, base64, os
for port in (80, 8072):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    req = ("GET /websocket HTTP/1.1\r\nHost: env-test.jcloud.ik-server.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: https://env-test.jcloud.ik-server.com\r\n"
           "X-Forwarded-Proto: https\r\n\r\n" % key)
    s.sendall(req.encode()); print(port, s.recv(300).decode(errors="replace").splitlines()[0], flush=True); s.close()
