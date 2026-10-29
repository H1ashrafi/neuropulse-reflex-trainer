from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from PIL import Image, ImageDraw, ImageFont

SUPERSAMPLE: Final[int] = 4
INK: Final[tuple[int, int, int, int]] = (242, 242, 242, 255)
VOID: Final[tuple[int, int, int, int]] = (0, 0, 0, 255)
CLEAR: Final[tuple[int, int, int, int]] = (0, 0, 0, 0)
SIGNAL_GREEN: Final[tuple[int, int, int, int]] = (74, 222, 128, 255)
MONOGRAM: Final[str] = "HX"
MONOGRAM_SHARE: Final[float] = 0.42
RING_DIVISOR: Final[int] = 24
DOT_DIVISOR: Final[int] = 9
DOT_OUTER: Final[float] = 2.2
DOT_INNER: Final[float] = 1.2
FONT_CANDIDATES: Final[tuple[str, ...]] = (
    "arialbd.ttf",
    "Arial Bold.ttf",
    "LiberationSans-Bold.ttf",
    "DejaVuSans-Bold.ttf",
)
LEGACY_LAUNCHER_PX: Final[dict[str, int]] = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}
ADAPTIVE_CANVAS_RATIO: Final[float] = 108 / 48
ADAPTIVE_LOGO_SHARE: Final[float] = 0.6
MASKABLE_LOGO_SHARE: Final[float] = 0.72
BRAND_PX: Final[int] = 512
FAVICON_PX: Final[int] = 32
WEB_ICON_PX: Final[tuple[int, ...]] = (192, 512)


class MissingFontError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class HixivMark:
    filled_disc: bool = True

    @staticmethod
    def _font(pixel_size: int) -> ImageFont.FreeTypeFont:
        for candidate in FONT_CANDIDATES:
            try:
                return ImageFont.truetype(candidate, pixel_size)
            except OSError:
                continue
        raise MissingFontError(f"none of {FONT_CANDIDATES} is installed")

    def render(
        self,
        size: int,
        logo_share: float = 1.0,
        backdrop: tuple[int, int, int, int] = CLEAR,
    ) -> Image.Image:
        canvas_px = size * SUPERSAMPLE
        logo_px = round(canvas_px * logo_share)
        inset = (canvas_px - logo_px) / 2
        far_edge = inset + logo_px - 1
        canvas = Image.new("RGBA", (canvas_px, canvas_px), backdrop)
        pen = ImageDraw.Draw(canvas)
        pen.ellipse(
            (inset, inset, far_edge, far_edge),
            fill=VOID if self.filled_disc else None,
            outline=INK,
            width=max(SUPERSAMPLE, logo_px // RING_DIVISOR),
        )
        font = self._font(int(logo_px * MONOGRAM_SHARE))
        left, top, right, bottom = pen.textbbox((0, 0), MONOGRAM, font=font)
        text_origin = (
            inset + (logo_px - (right - left)) / 2 - left,
            inset + (logo_px - (bottom - top)) / 2 - top,
        )
        pen.text(text_origin, MONOGRAM, font=font, fill=INK)
        dot_px = logo_px // DOT_DIVISOR
        corner = inset + logo_px
        pen.ellipse(
            (
                corner - dot_px * DOT_OUTER,
                corner - dot_px * DOT_OUTER,
                corner - dot_px * DOT_INNER,
                corner - dot_px * DOT_INNER,
            ),
            fill=SIGNAL_GREEN,
        )
        return canvas.resize((size, size), Image.Resampling.LANCZOS)


@dataclass(frozen=True, slots=True)
class IconForge:
    project_root: Path

    @property
    def android_res(self) -> Path:
        return self.project_root / "android" / "app" / "src" / "main" / "res"

    @property
    def web_dir(self) -> Path:
        return self.project_root / "web"

    def _save(self, image: Image.Image, target: Path) -> Path:
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target, format="PNG", optimize=True)
        return target

    def _android(self) -> list[Path]:
        disc = HixivMark(filled_disc=True)
        ring_only = HixivMark(filled_disc=False)
        written: list[Path] = []
        for density, legacy_px in LEGACY_LAUNCHER_PX.items():
            folder = self.android_res / f"mipmap-{density}"
            adaptive_px = round(legacy_px * ADAPTIVE_CANVAS_RATIO)
            written.append(self._save(disc.render(legacy_px), folder / "ic_launcher.png"))
            written.append(
                self._save(
                    ring_only.render(adaptive_px, logo_share=ADAPTIVE_LOGO_SHARE),
                    folder / "ic_launcher_foreground.png",
                )
            )
        return written

    def _web(self) -> list[Path]:
        disc = HixivMark(filled_disc=True)
        icons = self.web_dir / "icons"
        written = [self._save(disc.render(FAVICON_PX), self.web_dir / "favicon.png")]
        for size in WEB_ICON_PX:
            written.append(self._save(disc.render(size), icons / f"Icon-{size}.png"))
            written.append(
                self._save(
                    disc.render(size, logo_share=MASKABLE_LOGO_SHARE, backdrop=VOID),
                    icons / f"Icon-maskable-{size}.png",
                )
            )
        return written

    def build(self) -> list[Path]:
        brand = self.project_root / "assets" / "branding" / "hixiv_logo.png"
        return [self._save(HixivMark().render(BRAND_PX), brand), *self._android(), *self._web()]


def main(argv: list[str]) -> int:
    root = Path(argv[0]).resolve() if argv else Path(__file__).resolve().parent.parent
    if not (root / "pubspec.yaml").is_file():
        print(f"not a Flutter project: {root}", file=sys.stderr)
        return 2
    for path in IconForge(root).build():
        print(path.relative_to(root))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
