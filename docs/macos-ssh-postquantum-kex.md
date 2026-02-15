# macOS SSH Post-Quantum Key Exchange Fix

## The Problem

Starting with **macOS Tahoe (26.x)**, Apple ships OpenSSH 10.0+ which enables **post-quantum key exchange algorithms** by default:

- `mlkem768x25519-sha256`
- `sntrup761x25519-sha512`

Many network devices and embedded systems don't support these algorithms and will reject the connection with:

```
kex_exchange_identification: Connection closed by remote host
Connection reset by peer
```

**Known affected devices:**
- FortiGate firewalls (FortiOS 7.2.x and earlier)
- Older Cisco IOS devices
- Older MikroTik RouterOS
- Embedded Linux systems with older OpenSSH
- Any device running OpenSSH < 9.x

## The Fix

Force a compatible key exchange algorithm in your SSH connection:

```bash
ssh -o KexAlgorithms=ecdh-sha2-nistp256 admin@192.168.1.1
```

## Permanent Fix (SSH Config)

Add to `~/.ssh/config`:

```
# FortiGate — needs explicit kex due to macOS post-quantum defaults
Host fortigate
    HostName 192.168.x.x
    User admin
    PubkeyAuthentication no
    KexAlgorithms ecdh-sha2-nistp256
    StrictHostKeyChecking accept-new
```

## How to Diagnose

If you suspect this issue, run SSH with verbose logging:

```bash
ssh -vvv admin@192.168.1.1
```

Look for lines like:
```
debug1: kex: algorithm: mlkem768x25519-sha256
```

If you see a post-quantum algorithm being selected and the connection immediately drops, this is the issue.

## Supported Fallback Algorithms

In order of preference, these are widely supported:

1. `ecdh-sha2-nistp256` — most compatible
2. `ecdh-sha2-nistp384`
3. `ecdh-sha2-nistp521`
4. `diffie-hellman-group16-sha512`
5. `diffie-hellman-group14-sha256`

## Why This Happens

macOS 26.x's OpenSSH client offers post-quantum algorithms first during the key exchange negotiation. Devices that don't recognize these algorithms can't gracefully fall back — instead of trying the next algorithm in the list, they close the connection entirely.

This is a device firmware issue (they should skip unknown algorithms), but the practical fix is on the client side until vendors update their SSH implementations.

## References

- [OpenSSH 9.0 Release Notes](https://www.openssh.com/txt/release-9.0) — introduced post-quantum kex
- [Apple macOS Tahoe Security Notes](https://support.apple.com/en-us/HT213931)
