import socket
import threading
from dnslib import DNSRecord

# 🔥 Hardcode your corporate DNS server here
DNS_SERVER = "10.x.x.x"  # Replace with your actual corporate DNS server IP

def handle_request(data, addr, sock):
    try:
        # Parse the incoming DNS request
        request = DNSRecord.parse(data)
        query_name = str(request.q.qname)

        # Forward the request to the real corporate DNS server
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns_sock:
            dns_sock.sendto(data, (DNS_SERVER, 53))
            response_data, _ = dns_sock.recvfrom(512)

        # Send response back to WSL
        sock.sendto(response_data, addr)
        print(f"Resolved {query_name} via {DNS_SERVER}")

    except Exception as e:
        print(f"DNS Proxy Error: {e}")

def start_dns_proxy():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 5353))  # Listen on localhost:5353

    print(f"DNS Proxy started on 127.0.0.1:5353, forwarding to {DNS_SERVER}")

    while True:
        data, addr = sock.recvfrom(512)
        threading.Thread(target=handle_request, args=(data, addr, sock)).start()

if __name__ == "__main__":
    start_dns_proxy()
