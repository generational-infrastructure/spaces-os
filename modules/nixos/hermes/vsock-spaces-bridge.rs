// Per-connection spaces-gateway bridge for a hermes microvm.
//
// systemd (Accept=yes + StandardInput=socket) hands the accepted
// AF_VSOCK connection over as fd 0/1. vsock has neither file
// permissions nor netfilter mediation and ANY guest may dial ANY host
// vsock port — the hypervisor-guaranteed peer CID is the only access
// control. Reject unless it matches the expected CID (argv[1]); this
// check plays the role 0700 plays for a unix socket. Then connect to
// the owner's gateway socket — the unit runs as the owner, so it is
// /run/user/<euid>/spaces-integration-gateway.sock — and pump bytes
// both ways until EOF.
//
// No crates: std plus two extern "C" declarations (getpeername,
// geteuid) — the entire unsafe surface is those two calls and taking
// ownership of fd 0.

use std::io;
use std::net::Shutdown;
use std::os::fd::FromRawFd;
use std::os::unix::net::UnixStream;
use std::process::exit;

const AF_VSOCK: u16 = 40;

/// struct sockaddr_vm from <linux/vm_sockets.h> (fixed kernel ABI).
#[repr(C)]
struct SockaddrVm {
    svm_family: u16,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}

extern "C" {
    fn getpeername(fd: i32, addr: *mut SockaddrVm, len: *mut u32) -> i32;
    fn geteuid() -> u32;
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        let argv0 = args.first().map(String::as_str).unwrap_or("hermes-vsock-spaces-bridge");
        eprintln!("usage: {argv0} <expected-cid>");
        exit(2);
    }

    let want: u32 = match args[1].parse() {
        Ok(cid) if cid != 0 => cid,
        _ => {
            eprintln!("invalid cid: {}", args[1]);
            exit(2);
        }
    };

    let mut peer = SockaddrVm {
        svm_family: 0,
        svm_reserved1: 0,
        svm_port: 0,
        svm_cid: 0,
        svm_zero: [0; 4],
    };
    let mut len = std::mem::size_of::<SockaddrVm>() as u32;
    // SAFETY: fd 0 is open (systemd hands us the accepted socket as
    // stdin); `peer` and `len` are valid for writes and `len` holds the
    // buffer size, exactly the getpeername(2) contract. The kernel
    // never writes more than `len` bytes.
    let rc = unsafe { getpeername(0, &mut peer, &mut len) };
    if rc < 0 {
        eprintln!("getpeername(stdin): {}", io::Error::last_os_error());
        exit(1);
    }
    if peer.svm_family != AF_VSOCK || peer.svm_cid != want {
        let got = if peer.svm_family == AF_VSOCK { peer.svm_cid } else { 0 };
        // Grepped verbatim by the hermes-vm test — do not reword.
        eprintln!("rejecting connection: peer cid {got}, expected {want}");
        exit(1);
    }

    // SAFETY: geteuid(2) takes no arguments and cannot fail.
    let euid = unsafe { geteuid() };
    let path = format!("/run/user/{euid}/spaces-integration-gateway.sock");

    let gateway = match UnixStream::connect(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("connect {path}: {e}");
            exit(1);
        }
    };

    // SAFETY: fd 0 is the accepted SOCK_STREAM vsock connection and fd 1
    // is the same socket (StandardInput=socket); we take ownership of
    // fd 0 once, here, and never touch fd 0/1 again. UnixStream is used
    // purely for Read/Write/shutdown, which are family-agnostic on a
    // stream socket.
    let vsock = unsafe { UnixStream::from_raw_fd(0) };

    let (mut v_r, mut v_w) = match vsock.try_clone() {
        Ok(c) => (c, vsock),
        Err(e) => {
            eprintln!("dup vsock: {e}");
            exit(1);
        }
    };
    let (mut g_r, mut g_w) = match gateway.try_clone() {
        Ok(c) => (c, gateway),
        Err(e) => {
            eprintln!("dup gateway: {e}");
            exit(1);
        }
    };

    // Two directions; each half-closes its destination on EOF so the
    // peer sees end-of-stream. Errors (e.g. ECONNRESET) end that
    // direction like EOF. io::copy handles EINTR and partial writes.
    let vm_to_gw = std::thread::spawn(move || {
        let _ = io::copy(&mut v_r, &mut g_w);
        let _ = g_w.shutdown(Shutdown::Write);
    });
    let _ = io::copy(&mut g_r, &mut v_w);
    let _ = v_w.shutdown(Shutdown::Write);
    let _ = vm_to_gw.join();
}
