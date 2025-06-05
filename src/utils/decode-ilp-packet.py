#!/usr/bin/env python3
import base64
import json
import struct
import sys

def decode_ilp_packet(base64_packet):
    raw = base64.b64decode(base64_packet)
    if len(raw) < 3:
        raise ValueError("Invalid ILP packet: too short")

    packet_type = raw[0]
    packet_type_name = {
        0x0C: "ILP Prepare",
        0x0D: "ILP Fulfill",
        0x0E: "ILP Reject"
    }.get(packet_type, f"Unknown ({packet_type:#x})")

    packet_length = struct.unpack(">H", raw[1:3])[0]
    payload = raw[3:3+packet_length]

    print(f"\n=== ILP Packet ===")
    print(f"Packet Type: {packet_type_name}")
    print(f"Packet Length: {packet_length} bytes")

    if packet_type == 0x0C:  # Prepare
        amount, = struct.unpack(">Q", payload[0:8])
        destination, dest_len = _read_var_octet_string(payload[8:])
        data, _ = _read_var_octet_string(payload[8+dest_len:])
        print(f"Amount: {amount}")
        print(f"Destination: {destination}")
        try:
            json_data = json.loads(base64.b64decode(data).decode("utf8"))
            print("Data (decoded):")
            print(json.dumps(json_data, indent=2))
        except Exception as e:
            print("Data (raw):", data)

    elif packet_type == 0x0D:  # Fulfill
        fulfillment = payload[0:32].hex()
        data = payload[32:]
        print(f"Fulfillment: {fulfillment}")
        try:
            json_data = json.loads(data.decode("utf8"))
            print("Data (decoded):")
            print(json.dumps(json_data, indent=2))
        except Exception:
            print("Data (raw):", data)

    elif packet_type == 0x0E:  # Reject
        code = payload[0:3].decode("utf8")
        message_len = payload[3]
        message = payload[4:4+message_len].decode("utf8")
        triggered_by_len = payload[4+message_len]
        triggered_by = payload[5+message_len:5+message_len+triggered_by_len].decode("utf8")
        data = payload[5+message_len+triggered_by_len:]
        print(f"Code: {code}")
        print(f"Message: {message}")
        print(f"Triggered By: {triggered_by}")
        print("Data:", data)
    else:
        print("Unknown packet type. Raw payload:")
        print(payload)


def _read_var_octet_string(data):
    if len(data) < 1:
        raise ValueError("Cannot read varoctetstring: too short")
    length = data[0]
    return data[1:1+length].decode("utf8"), 1 + length


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python decode_ilp.py <base64_ilp_packet>")
        sys.exit(1)
    decode_ilp_packet(sys.argv[1])
