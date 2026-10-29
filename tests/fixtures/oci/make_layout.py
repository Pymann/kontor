#!/usr/bin/env python3
"""Writes a tiny, deterministic OCI image layout (for skopeo / curl tests).

    make_layout.py image <dir>        one-layer image, tag "1.0"
    make_layout.py run-layers <dir>   cosmos run-layers artifact (ecosystem.md §3),
                                      tag "run-42", three stage layers

Everything is reproducible: same bytes → same digests on every run.
"""
import gzip, hashlib, io, json, os, sys, tarfile

def tar_gz(files):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name in sorted(files):
            data = files[name].encode()
            info = tarfile.TarInfo(name)
            info.size, info.mtime, info.uid, info.gid, info.mode = len(data), 0, 0, 0, 0o644
            tar.addfile(info, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()

def put(root, data):
    digest = hashlib.sha256(data).hexdigest()
    os.makedirs(os.path.join(root, "blobs", "sha256"), exist_ok=True)
    with open(os.path.join(root, "blobs", "sha256", digest), "wb") as f:
        f.write(data)
    return {"digest": "sha256:" + digest, "size": len(data)}

def canon(obj):
    return json.dumps(obj, separators=(",", ":"), sort_keys=True).encode()

def image(root):
    layer = tar_gz({"hello.txt": "hello from kontor\n", "etc/os-release": "ID=kontor-test\n"})
    layer_desc = put(root, layer)
    diff_id = "sha256:" + hashlib.sha256(gzip.decompress(layer)).hexdigest()
    config = canon({"architecture": "amd64", "os": "linux",
                    "config": {"Cmd": ["/bin/true"]},
                    "rootfs": {"type": "layers", "diff_ids": [diff_id]}})
    manifest = canon({"schemaVersion": 2,
                      "mediaType": "application/vnd.oci.image.manifest.v1+json",
                      "config": dict(mediaType="application/vnd.oci.image.config.v1+json", **put(root, config)),
                      "layers": [dict(mediaType="application/vnd.oci.image.layer.v1.tar+gzip", **layer_desc)]})
    return manifest, "application/vnd.oci.image.manifest.v1+json", "1.0", None

STAGES = [("checkout", "", "opaque", "", "agent-a"),
          ("build", "arch=x86_64", "resolved", "k-1f2e3d", "agent-a"),
          ("test", "arch=x86_64,os=linux", "pure", "k-9a8b7c", "agent-b")]

def run_layers(root):
    layers = []
    for idx, (stage, bindings, reuse, key, agent) in enumerate(STAGES):
        blob = tar_gz({f"{stage}/out.txt": f"stage {idx} {stage}\n"})
        layers.append(dict(mediaType="application/vnd.oci.image.layer.v1.tar+gzip", **put(root, blob),
                           annotations={"cosmos.stage": stage, "cosmos.bindings": bindings,
                                        "cosmos.reuse": reuse, "cosmos.step_key": key,
                                        "cosmos.agent": agent}))
    config = canon({"run_id": "run-42", "pipeline": "demo", "base": "debian:12"})
    artifact = "application/vnd.cosmos.run-layers.v1+json"
    manifest = canon({"schemaVersion": 2,
                      "mediaType": "application/vnd.oci.image.manifest.v1+json",
                      "artifactType": artifact,
                      "config": dict(mediaType="application/vnd.cosmos.run-layers.config.v1+json", **put(root, config)),
                      "layers": layers})
    return manifest, "application/vnd.oci.image.manifest.v1+json", "run-42", artifact

def main():
    kind, root = sys.argv[1], sys.argv[2]
    os.makedirs(root, exist_ok=True)
    manifest, media, tag, artifact = {"image": image, "run-layers": run_layers}[kind](root)
    desc = dict(mediaType=media, **put(root, manifest),
                annotations={"org.opencontainers.image.ref.name": tag})
    if artifact:
        desc["artifactType"] = artifact
    with open(os.path.join(root, "oci-layout"), "w") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)
    with open(os.path.join(root, "index.json"), "w") as f:
        json.dump({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
                   "manifests": [desc]}, f)
    print(desc["digest"])

if __name__ == "__main__":
    main()
