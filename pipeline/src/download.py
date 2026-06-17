"""
Fetch and cache geodata: Natural Earth 110m land polygons and ETOPO elevation.

Usage:
    python pipeline/src/download.py
    python pipeline/src/download.py --etopo
    python pipeline/src/download.py --config pipeline/config/planet.yaml --root .

Natural Earth downloads to data/cache/ne_110m_land.zip, extracts to data/cache/ne_110m_land/.
ETOPO downloads to data/cache/etopo_60s.nc (~400-800 MB, cached for 365 days).
"""

import argparse
import time
import zipfile
from pathlib import Path

import requests
import yaml

NE_URL = "https://naciscdn.org/naturalearth/10m/physical/ne_10m_land.zip"
CACHE_ZIP_REL = Path("data/cache/ne_10m_land.zip")
CACHE_DIR_REL = Path("data/cache/ne_10m_land")
SHP_NAME = "ne_10m_land.shp"

NE_LAKES_URL = "https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip"
LAKES_ZIP_REL = Path("data/cache/ne_10m_lakes.zip")
LAKES_DIR_REL = Path("data/cache/ne_10m_lakes")
LAKES_SHP_NAME = "ne_10m_lakes.shp"

ETOPO_URL = (
    "https://www.ngdc.noaa.gov/thredds/fileServer/global/ETOPO2022/60s/"
    "60s_bed_elev_netcdf/ETOPO_2022_v1_60s_N90W180_bed.nc"
)
ETOPO_CACHE_REL = Path("data/cache/etopo_60s.nc")

KOPPEN_URL = "https://figshare.com/ndownloader/files/12407516"
KOPPEN_ZIP_REL = Path("data/cache/koppen_beck2018.zip")
KOPPEN_TIF_REL = Path("data/cache/koppen_beck2018.tif")


def load_config(config_path: Path) -> dict:
    with config_path.open() as f:
        return yaml.safe_load(f)


def _is_fresh(path: Path, ttl_days: int) -> bool:
    if not path.exists():
        return False
    age_days = (time.time() - path.stat().st_mtime) / 86400
    return age_days < ttl_days


def download(config: dict, repo_root: Path) -> Path:
    """Download and cache ne_110m_land.shp. Returns the path to the .shp file."""
    ttl_days = config.get("cache", {}).get("osm_ttl_days", 7)

    cache_zip = repo_root / CACHE_ZIP_REL
    cache_dir = repo_root / CACHE_DIR_REL
    shp_path = cache_dir / SHP_NAME

    if _is_fresh(shp_path, ttl_days):
        print(f"Cache hit: {shp_path}")
        return shp_path

    cache_zip.parent.mkdir(parents=True, exist_ok=True)

    print(f"Downloading {NE_URL} ...")
    resp = requests.get(NE_URL, timeout=60)
    resp.raise_for_status()
    cache_zip.write_bytes(resp.content)
    print(f"Saved {len(resp.content) // 1024} KB to {cache_zip}")

    cache_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(cache_zip) as zf:
        zf.extractall(cache_dir)
    print(f"Extracted to {cache_dir}")

    if not shp_path.exists():
        raise FileNotFoundError(
            f"Expected shapefile not found after extraction: {shp_path}\n"
            f"Contents: {list(cache_dir.iterdir())}"
        )

    return shp_path


def download_lakes(config: dict, repo_root: Path) -> Path:
    """Download and cache ne_10m_lakes.shp. Returns the path to the .shp file."""
    ttl_days = config.get("cache", {}).get("osm_ttl_days", 7)

    cache_zip = repo_root / LAKES_ZIP_REL
    cache_dir = repo_root / LAKES_DIR_REL
    shp_path = cache_dir / LAKES_SHP_NAME

    if _is_fresh(shp_path, ttl_days):
        print(f"Cache hit: {shp_path}")
        return shp_path

    cache_zip.parent.mkdir(parents=True, exist_ok=True)

    print(f"Downloading {NE_LAKES_URL} ...")
    resp = requests.get(NE_LAKES_URL, timeout=60)
    resp.raise_for_status()
    cache_zip.write_bytes(resp.content)
    print(f"Saved {len(resp.content) // 1024} KB to {cache_zip}")

    cache_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(cache_zip) as zf:
        zf.extractall(cache_dir)
    print(f"Extracted to {cache_dir}")

    if not shp_path.exists():
        raise FileNotFoundError(
            f"Expected shapefile not found after extraction: {shp_path}\n"
            f"Contents: {list(cache_dir.iterdir())}"
        )

    return shp_path


def download_etopo(config: dict, repo_root: Path) -> Path:
    """Download and cache ETOPO 2022 60-arc-second NetCDF. Returns path to .nc file."""
    ttl_days = config.get("cache", {}).get("etopo_ttl_days", 365)
    cache_nc = repo_root / ETOPO_CACHE_REL

    if _is_fresh(cache_nc, ttl_days):
        print(f"Cache hit: {cache_nc}")
        return cache_nc

    cache_nc.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading ETOPO 2022 (~400-800 MB) to {cache_nc} ...")
    print("This may take several minutes depending on your connection.")

    with requests.get(ETOPO_URL, stream=True, timeout=600) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("content-length", 0))
        downloaded = 0
        with cache_nc.open("wb") as f:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                f.write(chunk)
                downloaded += len(chunk)
                if total:
                    pct = downloaded / total * 100
                    mb = downloaded // (1024 * 1024)
                    print(
                        f"\r  {mb} MB / {total // (1024 * 1024)} MB ({pct:.1f}%)",
                        end="",
                        flush=True,
                    )
    print(f"\nSaved {downloaded // (1024 * 1024)} MB to {cache_nc}")
    return cache_nc


def _is_tiff(path: Path) -> bool:
    magic = path.read_bytes()[:4]
    return magic[:2] in (b"II", b"MM")  # little-endian or big-endian TIFF


def download_koppen(config: dict, repo_root: Path) -> Path:
    """Download and cache Beck 2018 Köppen-Geiger GeoTIFF. Returns path to .tif file."""
    ttl_days = config.get("cache", {}).get("koppen_ttl_days", 365)
    cache_raw = repo_root / KOPPEN_ZIP_REL
    cache_tif = repo_root / KOPPEN_TIF_REL

    if _is_fresh(cache_tif, ttl_days):
        print(f"Cache hit: {cache_tif}")
        return cache_tif

    cache_raw.parent.mkdir(parents=True, exist_ok=True)

    print("Downloading Beck 2018 Köppen-Geiger (~30 MB) ...")
    with requests.get(KOPPEN_URL, stream=True, timeout=120, allow_redirects=True) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("content-length", 0))
        downloaded = 0
        with cache_raw.open("wb") as f:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                f.write(chunk)
                downloaded += len(chunk)
                if total:
                    pct = downloaded / total * 100
                    mb = downloaded // (1024 * 1024)
                    print(
                        f"\r  {mb} MB / {total // (1024 * 1024)} MB ({pct:.1f}%)",
                        end="",
                        flush=True,
                    )
    print(f"\nSaved {downloaded // (1024 * 1024)} MB ({downloaded:,} bytes)")

    MIN_BYTES = 1024 * 1024  # anything under 1 MB is certainly not geodata
    if downloaded < MIN_BYTES:
        cache_raw.unlink(missing_ok=True)
        raise RuntimeError(
            f"Download too small ({downloaded} bytes) — figshare may have returned an HTML page.\n"
            f"Try opening {KOPPEN_URL} in a browser and downloading manually to {cache_tif}"
        )

    # Figshare may serve the file as a bare GeoTIFF or inside a zip.
    if _is_tiff(cache_raw):
        cache_raw.rename(cache_tif)
        print(f"File is a bare GeoTIFF — saved to {cache_tif}")
    else:
        with zipfile.ZipFile(cache_raw) as zf:
            tif_names = [n for n in zf.namelist() if n.lower().endswith(".tif")]
            if not tif_names:
                raise FileNotFoundError(f"No .tif found in zip. Contents: {zf.namelist()}")
            zf.extract(tif_names[0], cache_raw.parent)
            extracted = cache_raw.parent / tif_names[0]
            extracted.rename(cache_tif)
        cache_raw.unlink(missing_ok=True)
        print(f"Extracted to {cache_tif}")

    return cache_tif


def main() -> None:
    parser = argparse.ArgumentParser(description="Download geodata for the tiny-earth pipeline.")
    parser.add_argument("--config", default="pipeline/config/planet.yaml")
    parser.add_argument("--root", default=".")
    parser.add_argument("--etopo", action="store_true", help="Download ETOPO elevation NetCDF")
    parser.add_argument(
        "--lakes", action="store_true", help="Download Natural Earth 10m lakes shapefile"
    )
    parser.add_argument(
        "--koppen", action="store_true", help="Download Beck 2018 Köppen-Geiger GeoTIFF"
    )
    args = parser.parse_args()

    config = load_config(Path(args.config))
    repo_root = Path(args.root).resolve()

    if args.etopo:
        nc = download_etopo(config, repo_root)
        print(f"ETOPO ready: {nc}")
    elif args.lakes:
        shp = download_lakes(config, repo_root)
        print(f"Lakes shapefile ready: {shp}")
    elif args.koppen:
        tif = download_koppen(config, repo_root)
        print(f"Köppen ready: {tif}")
    else:
        shp = download(config, repo_root)
        print(f"Shapefile ready: {shp}")


if __name__ == "__main__":
    main()
