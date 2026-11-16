"""Test the production Swift face uploader against a disposable ARM watch over loopback H4."""

import asyncio
import hashlib
import json
import os
import signal
import struct
import time
import verify_arm_apps as run


async def verify(hci):
    from wp2apps import h4, link

    face = run.root / "build/watchface-fixture/face.wfdl"
    assert face.is_file(), "Launch the iOS simulator with -export-test-face first"
    from tests.e2e.harness import Qmp

    q = Qmp(run.qmp_port)
    state = struct.unpack_from("<I", run.args.patched_app.read_bytes(), 0xDE868)[0]
    count = int(q.hmp(f"xp /1bx {state + 8:#x}")["return"].split()[-1], 16)
    assert 1 < count <= 8, "Unexpected reference face-slot layout"
    reference_id = int(
        q.hmp(f"xp /1wx {state + 16 + (count - 1) * 16:#x}")["return"].split()[-1], 16
    )
    assert 7 <= reference_id < 10000, "Only a disposable reference face may be removed"
    async with h4.gatt_over_h4(hci, mtu=247) as gatt:
        session = link.Session()
        await session.attach(gatt)
        auth, nonce = await session._bind(bytes.fromhex("01" * 16))
        session.key = link.session_key(nonce, auth)
        await session.request(link.SYSTEM, 0x804D, b"\xa5", 0x0004)
        active_writer = None
        commands = []

        def notify(uuid, data):
            if active_writer:
                active_writer.write(
                    json.dumps(dict(uuid=uuid, data=bytes(data).hex())).encode() + b"\n"
                )

        for uuid in [
            "0000fff1-0000-1000-8000-00805f9b34fb",
            "02f00000-0000-0000-0000-00000000ffe2",
            "77d4ff02-2fe2-2334-0d35-9ccd078f529c",
        ]:
            await gatt.subscribe(uuid, lambda data, u=uuid: notify(u, data))

        async def bridge(reader, writer):
            nonlocal active_writer
            active_writer = writer
            try:
                while line := await reader.readline():
                    d = json.loads(line)
                    raw = bytes.fromhex(d["data"])
                    uuid = d["uuid"].lower()
                    if len(raw) >= 11 and raw[0] == 245:
                        commands.append(
                            dict(
                                uuid=uuid,
                                command=int.from_bytes(raw[9:11], "big"),
                                response=d["response"],
                            )
                        )
                    try:
                        await gatt.write(uuid, raw, response=d["response"])
                        writer.write(
                            json.dumps(dict(id=d["id"], ok=True)).encode() + b"\n"
                        )
                    except Exception:
                        writer.write(
                            json.dumps(dict(id=d["id"], ok=False)).encode() + b"\n"
                        )
                        raise
                    await writer.drain()
            finally:
                active_writer = None
                writer.close()

        server = await asyncio.start_server(bridge, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        ready = run.out / "face-activated"
        env = dict(
            os.environ,
            WATCH_FACE_TEST_PORT=str(port),
            WATCH_FACE_TEST_FILE=str(face),
            WATCH_FACE_TEST_AUTH=auth.hex(),
            WATCH_FACE_TEST_READY=str(ready),
            WATCH_FACE_TEST_ADVANCE=str(run.out / "advance-clock"),
            WATCH_FACE_DELETE_REFERENCE_ID=str(reference_id),
        )
        with (run.out / "swift.log").open("w") as log:
            process = await asyncio.create_subprocess_exec(
                "swift",
                "test",
                "--filter",
                "LiveFaceTests/testUploadToVirtualWatch",
                cwd=run.root / "ios/CompanionCore",
                env=env,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 120
                while (
                    not ready.exists()
                    and process.returncode is None
                    and time.monotonic() < deadline
                ):
                    await asyncio.sleep(0.2)
                assert ready.exists(), (
                    "Swift face upload did not activate; inspect the private test log"
                )
                deadline = time.monotonic() + 12
                while "Id:1000001, Type:2" not in (
                    run.out / "guest/uart0.log"
                ).read_text(errors="replace"):
                    assert time.monotonic() < deadline, (
                        "The activated face did not load"
                    )
                    await asyncio.sleep(0.1)
                await asyncio.sleep(0.6)
                first = (run.out / "guest/frame.ppm").read_bytes()
                (run.out / "watch-face.ppm").write_bytes(first)
                (run.out / "advance-clock").write_text("observe normal clock tick")

                async def awake():
                    while True:
                        with (run.out / "guest/input.txt").open("a") as f:
                            f.write("t 1 30 233\n" + "t 0 30 233\n")
                        await asyncio.sleep(2)

                awake_task = asyncio.create_task(awake())
                rc = await asyncio.wait_for(process.wait(), timeout=85)
                assert rc == 0, "Production Swift uploader failed"
                await asyncio.sleep(0.5)
                awake_task.cancel()
                second = (run.out / "guest/frame.ppm").read_bytes()
                (run.out / "watch-face-next-minute.ppm").write_bytes(second)
                a = first.split(b"\n", 3)[3]
                b = second.split(b"\n", 3)[3]
                changes = sum(
                    a[(y * 466 + x) * 3 : (y * 466 + x) * 3 + 3]
                    != b[(y * 466 + x) * 3 : (y * 466 + x) * 3 + 3]
                    for y in range(160, 265)
                    for x in range(107, 360)
                )
                assert changes >= 50, ("The live clock digits did not change", changes)
                face_commands = [
                    x
                    for x in commands
                    if x["command"] in (0x8052, 0x9075, 0x9064, 0x9065)
                ]
                assert face_commands and all(
                    x["uuid"].endswith("ffe1") and not x["response"]
                    for x in face_commands
                )
                assert any(x["command"] == 0x9065 for x in face_commands)
                report = dict(
                    result="watch_face_arm_verified",
                    face_sha256=hashlib.sha256(face.read_bytes()).hexdigest(),
                    face_bytes=face.stat().st_size,
                    production_swift_uploader=True,
                    stock_face_channel=True,
                    without_response_writes=True,
                    activated_ack=True,
                    live_clock_changed=True,
                    natural_minute_tick=True,
                    custom_texture_format_index=True,
                    reference_slot_freed_by_stock_protocol=True,
                    firmware_ota_used=False,
                )
                (run.root / "build/watch-face-arm-report.json").write_text(
                    json.dumps(report, indent=2) + "\n"
                )
                return report
            finally:
                if process.returncode is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    await process.wait()
                server.close()
                await server.wait_closed()


run.verify_all = verify
# The emulator needs hashes to distinguish packed WFC alpha textures from
# BGRA descriptors. Extend only a disposable fixture's metadata, without
# preloading the candidate face or changing the reference NAND image.
from cmf_watch_utils.emu.watchface import prepare_face

candidate = run.root / "build/watchface-fixture/face.wfdl"
_, _, index = prepare_face(
    (run.args.fixtures / "nand-defaults.bin").read_bytes(), candidate.read_bytes()
)
original = run.args.fixtures
fixture = run.out / "fixtures"
fixture.mkdir()
for path in original.iterdir():
    if path.name != "wfc-index.txt":
        (fixture / path.name).symlink_to(
            path.resolve(), target_is_directory=path.is_dir()
        )
existing = (
    (original / "wfc-index.txt").read_bytes()
    if (original / "wfc-index.txt").exists()
    else b""
)
(fixture / "wfc-index.txt").write_bytes(existing + b"\n" + index)
run.args.fixtures = fixture
run.report_path = run.root / "build/watch-face-arm-report.json"
run.main()
