#!/usr/bin/env python3
"""Mint Access-shaped JWTs for the forward-auth tests.

Signing is deliberately done with openssl rather than with the verifier's own
code, so that a bug in the verifier cannot cancel itself out in the test.
"""

import base64
import json
import os
import socket
import subprocess
import sys
import time


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def keygen(directory: str) -> None:
    os.makedirs(directory, exist_ok=True)
    key = os.path.join(directory, "key.pem")
    subprocess.run(
        ["openssl", "genrsa", "-out", key, "2048"],
        check=True,
        stderr=subprocess.DEVNULL,
    )
    modulus = subprocess.run(
        ["openssl", "rsa", "-in", key, "-noout", "-modulus"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    n = bytes.fromhex(modulus.split("=", 1)[1])
    # openssl genrsa uses F4, and nothing here asks it not to.
    jwks = {
        "keys": [
            {
                "kid": "testkey",
                "kty": "RSA",
                "alg": "RS256",
                "use": "sig",
                "e": b64url((65537).to_bytes(3, "big")),
                "n": b64url(n),
            }
        ]
    }
    with open(os.path.join(directory, "jwks.json"), "w") as handle:
        json.dump(jwks, handle)


def sign(directory: str, header: dict, payload: dict) -> str:
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.path.join(directory, "key.pem")],
        input=signing_input.encode(),
        check=True,
        capture_output=True,
    ).stdout
    return f"{signing_input}.{b64url(signature)}"


def token(directory: str, overrides: dict) -> str:
    now = int(time.time())
    header = {"alg": "RS256", "kid": "testkey", "typ": "JWT"}
    payload = {
        "aud": ["aud-llama"],
        "iss": "https://acme.cloudflareaccess.com",
        "email": "someone@example.com",
        "sub": "a1b2c3",
        "iat": now - 10,
        "nbf": now - 10,
        "exp": now + 600,
    }
    header.update(overrides.pop("header", {}))
    payload.update(overrides)
    return sign(directory, header, payload)


def freeport() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main() -> None:
    command = sys.argv[1]
    if command == "keygen":
        keygen(sys.argv[2])
    elif command == "token":
        overrides = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
        print(token(sys.argv[2], overrides))
    elif command == "freeport":
        print(freeport())
    else:
        raise SystemExit(f"unknown command: {command}")


if __name__ == "__main__":
    main()
