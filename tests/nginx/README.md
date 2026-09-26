# tests/nginx - the nginx test for the TC002

Everything needed to check this project's nginx on the device, in one directory: a configuration written for this
exact build, a test page, a script that makes a throwaway certificate, and a script that runs the whole test.

| File | What it is |
|---|---|
| [`nginx.conf`](nginx.conf) | The test configuration: HTTP on 8080 (with `stub_status` and a `map` example), HTTPS on 8443 (TLS 1.2 and 1.3) |
| [`www/index.html`](www/index.html) | The page it serves |
| [`make_cert.sh`](make_cert.sh) | Makes a self-signed certificate + key on your **host** (`rsa` or `ec`) |
| [`run_test.sh`](run_test.sh) | Runs everything end to end from your host (an RSA and an ECDSA step) and prints OK/FAIL per check |

## What to type

nginx has to be deployed first (`./build_nginx.sh`, then `install/install_on_demand.sh` or a full `./tc002_setup.sh`;
`/data/bin/nginx` must exist on the device). Then, from the repository root:

```sh
tests/nginx/run_test.sh
```

That runs two steps, one with an RSA certificate and one with an ECDSA certificate. `--cert rsa` or `--cert ec` runs
just one of them. It uses `DEVICE_IP` (or `DEVICE`) from `config/tc002-tools.conf` like the install scripts do. Other
options: `--ip ADDRESS` (the address curl tests against, if it differs from `DEVICE_IP`), `--keep` (leave nginx running
and `/tmp/ngx` in place so you can poke at it), `--verbose` (always show `nginx -t` and the details), `--device`,
`--config`.

The script:
1. pushes the config and the page to `/tmp/ngx` on the device;
2. **RSA step:** makes an RSA certificate on your host (the OpenSSL CLI is **not** needed on the device, which has very
   little RAM), pushes it, checks the configuration (`nginx -t`), starts nginx through the on-demand wrapper and tests
   from the host with curl: the page over HTTP, the `map` header, `stub_status`, and HTTPS forced to TLS 1.2 and to
   TLS 1.3;
3. **ECDSA step:** stops nginx, swaps in an ECDSA certificate, starts it again and repeats the two HTTPS checks (the
   HTTP checks do not depend on the certificate);
4. stops nginx and deletes `/tmp/ngx` (unless `--keep`), and prints the device's free memory before, while running and
   after - so a leak would be visible.

A typical good run ends with `RESULT: 8 passed, 0 failed` (`nginx -t`, three HTTP checks, and two TLS checks per
certificate), and the free memory afterwards is back near where it started. Every curl request has a time limit, so a
stall (for example a wait for random numbers, see [../../curl/README.md](../../curl/README.md)) shows up as a `FAIL`,
not as a hung test. On a failure the script prints the nginx error log from the device.

## What this nginx can and cannot do

The configuration only uses what this build has (see [nginx/README.md](../../nginx/README.md)):
- **No PCRE and no rewrite module**, so there is no `return`, `if`, `set` or `rewrite`, and `map` works with exact and
  wildcard names but not with regular-expression patterns (`~`, `~*`).
- **`user root;`** is needed: there is no `nobody` account on the device.
- **Ports 8080 and 8443**, because port 80 is used by the device's own web UI (`zkgui`).
- **TLS 1.2 and 1.3 only** - the OpenSSL linked in has TLS 1.0/1.1, DTLS, QUIC, OCSP and a number of old ciphers compiled
  out (see [../../openssl/README.md](../../openssl/README.md)). A client that insists on one of those cannot connect.
- Everything lives under `/tmp/ngx`, which is **RAM** (about 36 MB in total on this device): the pid file, logs and
  certificate too. Nothing is written to flash.

## Doing it by hand

If you want to see the steps (or the script fails somewhere and you need to look around), this is all it does. On your
host:

```sh
tests/nginx/make_cert.sh rsa /tmp/tc002-cert
```

Push the files (the device needs the directory first, from `adb shell mkdir -p /tmp/ngx/www /tmp/ngx/logs`):

```sh
adb push tests/nginx/nginx.conf /tmp/ngx/nginx.conf
```

```sh
adb push tests/nginx/www/index.html /tmp/ngx/www/index.html
```

```sh
adb push /tmp/tc002-cert/c.pem /tmp/ngx/c.pem
```

```sh
adb push /tmp/tc002-cert/k.pem /tmp/ngx/k.pem
```

On the device (over SSH):

```sh
nginx -p /tmp/ngx -c /tmp/ngx/nginx.conf -t
```

```sh
nginx -p /tmp/ngx -c /tmp/ngx/nginx.conf
```

From the host:

```sh
curl -k https://DEVICE_IP:8443/
```

Stop it again with `nginx -p /tmp/ngx -s stop` and free the RAM with `rm -rf /tmp/ngx`.

## The certificate

`make_cert.sh` makes a self-signed certificate that is valid for 7 days, so clients need `-k` (curl) or an exception.
The files are **never committed**: `*.pem` is in `.gitignore`, and a private key checked into a public repository would
be flagged by secret scanners even as test material. Use `make_cert.sh` for a fresh one every time. For a
certificate signed by a real CA, put your own `c.pem` and `k.pem` in `/tmp/ngx` (or change the paths in `nginx.conf`).
