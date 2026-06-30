import socket
subnets = [
    ('192.168.1', range(1, 20)),
    ('192.168.2', range(1, 20)),
]
for net, rng in subnets:
    for i in rng:
        ip = f'{net}.{i}'
        s = socket.socket()
        s.settimeout(0.3)
        if s.connect_ex((ip, 554)) == 0:
            print(f'RTSP FOUND: {ip}:554')
        s.close()
print('Scan done')
