#!/usr/bin/env python3
import argparse, re, sys, math

FLOAT = r"([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"

def is_num(x: str) -> bool:
    try:
        float(x); return True
    except:
        return False

def parse_pqc_row(text: str, alg: str):
    # Expected table row: "<alg> ... keygens/s sign/s verify/s" (numbers at end)
    for line in text.splitlines():
        parts = line.strip().split()
        if not parts:
            continue
        if parts[0] == alg:
            nums = [p for p in parts if is_num(p)]
            if len(nums) >= 3:
                return nums[-3], nums[-2], nums[-1]
    return None

def parse_ecdsap256(text: str):
    # Try 1: line starting with "ecdsap256"
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("ecdsap256"):
            parts = s.split()
            nums = [p for p in parts if is_num(p)]
            # Often only sign/s verify/s appear as last two numeric tokens
            if len(nums) >= 2:
                return "", nums[-2], nums[-1]
    # Try 2: legacy formats (look for nistp256/prime256v1/secp256r1 and grab last two numbers)
    pat = re.compile(r"(ecdsa).*?(nistp256|prime256v1|secp256r1).*")
    for line in text.splitlines():
        if pat.search(line.lower()):
            parts = line.strip().split()
            nums = [p for p in parts if is_num(p)]
            if len(nums) >= 2:
                return "", nums[-2], nums[-1]
    # Try 3: if output contains "256 bits" and "ECDSA"
    for line in text.splitlines():
        low = line.lower()
        if "ecdsa" in low and ("256" in low or "p-256" in low):
            parts = line.strip().split()
            nums = [p for p in parts if is_num(p)]
            if len(nums) >= 2:
                return "", nums[-2], nums[-1]
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--alg", required=True, help="Algorithm name: ecdsap256|mldsa44|mldsa65|falcon512|falcon1024|...")
    ap.add_argument("--raw", required=True, help="Path to raw openssl speed output")
    args = ap.parse_args()

    with open(args.raw, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()

    alg = args.alg.strip()

    if alg == "ecdsap256":
        out = parse_ecdsap256(text)
        if not out:
            print("ERROR:ECDSA_ROW_NOT_FOUND", file=sys.stderr)
            sys.exit(2)
        keygen, sign, verify = out
    else:
        out = parse_pqc_row(text, alg)
        if not out:
            print("ERROR:PQC_ROW_NOT_FOUND", file=sys.stderr)
            sys.exit(2)
        keygen, sign, verify = out

    # Validate numeric fields (keygen may be empty for ecdsa)
    if keygen and not is_num(keygen):
        print("ERROR:KEYGEN_NON_NUMERIC", file=sys.stderr); sys.exit(3)
    if sign and not is_num(sign):
        print("ERROR:SIGN_NON_NUMERIC", file=sys.stderr); sys.exit(3)
    if verify and not is_num(verify):
        print("ERROR:VERIFY_NON_NUMERIC", file=sys.stderr); sys.exit(3)

    # Output as CSV fragment: keygens_s,sign_s,verify_s
    print(f"{keygen},{sign},{verify}")

if __name__ == "__main__":
    main()
