import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory
from urllib.request import urlopen
from zipfile import ZipFile


# The ByteBooks branch is the version verified against a real Libby loan.
ACSM_INPUT = (
    "Leseratte10/acsm-calibre-plugin",
    "636648485984212c55245846217bfa53a1628d9d",
    "6819b8e36b23fa787a3d6fe375a8a8989429ba57908a2c70e279afaee692230f",
)
DEDRM = (
    "noDRM/DeDRM_tools",
    "7379b453199ed1ba91bf3a4ce4875d5ed3c309a9",
    "8edc39962c6f7fbcf8aa059ee1e935c3710c9a5374cc3a8fd3db148662c0bd9e",
)


def prepare_upload_validator():
    # v4.1.74 expects text/xml for ACSM. Libby and ByteBooks also send valid
    # tickets without an XML declaration, which libmagic calls text/plain.
    upstream = Path("/app/calibre-web-automated/cps/file_helper.py").read_text()
    signature = "def validate_mime_type(file_buffer, allowed_extensions):\n"
    if upstream.count(signature) != 1:
        raise RuntimeError("NextGen upload validator changed; recheck the ACSM compatibility patch")
    acsm_validation = '''    if ("acsm" in allowed_extensions
            and getattr(file_buffer, "filename", "").lower().endswith(".acsm")):
        from lxml import etree

        max_ticket_bytes = 128 * 1024
        payload = file_buffer.read(max_ticket_bytes + 1)
        file_buffer.seek(0)
        if len(payload) > max_ticket_bytes:
            return False
        try:
            parser = etree.XMLParser(resolve_entities=False, load_dtd=False, no_network=True)
            root = etree.fromstring(payload, parser)
        except etree.XMLSyntaxError:
            return False
        return (root.tag == "{http://ns.adobe.com/adept}fulfillmentToken"
                and not root.getroottree().docinfo.doctype)
'''
    Path("/runtime/file_helper.py").write_text(upstream.replace(signature, signature + acsm_validation))


def verified_source(destination, source):
    repository, revision, expected_digest = source
    project = repository.split("/")[1]
    archive = destination / f"{project}.tar.gz"
    with urlopen(f"https://codeload.github.com/{repository}/tar.gz/{revision}", timeout=30) as response:
        archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected_digest:
        raise RuntimeError(f"Source checksum mismatch for {repository}")
    with tarfile.open(archive) as compressed:
        compressed.extractall(destination, filter="data")
    return destination / f"{project}-{revision}"


def configure_acsm():
    calibre_config = Path("/config/.config/calibre")
    plugins = calibre_config / "plugins"
    activation = plugins / "ACSMInput/account"
    activation.mkdir(parents=True, mode=0o700, exist_ok=True)

    # Stage the SOPS-managed device authorization in the location ACSM Input
    # uses. It stays on the PVC so Calibre can update its own settings nearby.
    for filename in ("activation.xml", "device.xml", "devicesalt"):
        secret = (Path("/acsm-activation") / filename).read_bytes()
        target = activation / filename
        if target.is_file() and target.read_bytes() == secret:
            continue
        with NamedTemporaryFile(dir=activation, delete=False) as temporary:
            temporary.write(secret)
        Path(temporary.name).replace(target)

    revisions = f"{ACSM_INPUT[1]}\n{DEDRM[1]}\n"
    marker = calibre_config / ".home-cluster-plugin-revisions"
    if (marker.is_file() and marker.read_text() == revisions
            and all((plugins / name).is_file() for name in ("ACSM Input.zip", "DeDRM.zip"))):
        return

    with TemporaryDirectory(prefix="calibre-acsm-") as directory:
        work = Path(directory)
        acsm_source = verified_source(work, ACSM_INPUT)
        acsm_zip = shutil.make_archive(str(work / "acsm-input"), "zip", acsm_source / "calibre-plugin")
        dedrm_source = verified_source(work, DEDRM)
        # The upstream packager adds Calibre's import compatibility code.
        subprocess.run([sys.executable, "make_release.py"], cwd=dedrm_source, check=True)
        with ZipFile(dedrm_source / "DeDRM_tools.zip") as release:
            dedrm_zip = work / "DeDRM_plugin.zip"
            dedrm_zip.write_bytes(release.read(dedrm_zip.name))

        environment = dict(os.environ, HOME="/config", QT_QPA_PLATFORM="offscreen",
                           CALIBRE_CONFIG_DIRECTORY=str(calibre_config))
        for plugin in (acsm_zip, dedrm_zip):
            subprocess.run(["calibre-customize", "--add-plugin", plugin], env=environment, check=True)
        marker.write_text(revisions)
