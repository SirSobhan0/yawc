# Yet Another Wallpaper Carousel (yawc)

Pronunciation: /jˈɔːk/ (yawk)

![preview photo](assets/preview.png)

yawc is a stylish, lightweight wallpaper selector interface for Wayland built with Quickshell and QML. It presents your wallpaper collection in an animated, slanted horizontal carousel for quick previewing and selection.

⚡ Note: This project was vibe coded.

## Features

Carousel UI: Smooth, angled horizontal card view with animated focus transitions.

Parallax Cropping: Each card reveals the part of its photo matching its position on screen — cards on the left show the left of the image, the centred card shows the middle. Tunable via `parallax_strength`.

Fast Loading: Small JPEG previews are cached on disk, so launches after the first render near-instantly instead of decoding every full-size image. Full-resolution versions fade in afterwards.

Flexible Configuration: Reads YAML configuration files (config.yaml / config.yml) and supports custom file overrides using the YAWC_CONFIG environment variable. Card sizing, backdrop opacity, animations, and cache behaviour are all configurable.

Custom Execution: Works with any Wayland wallpaper daemon (swww, hyprpaper, mpvpaper, etc.) via customizable commands.

## Requirements

- [Quickshell](https://quickshell.outfoxxed.me/)
- `python3` with PyYAML — configuration parsing
- `python3` Pillow (`python3-pil`) — *optional*, only for the thumbnail cache. Without it yawc still runs and simply loads full-size images directly; set `thumbnail_cache: false` to disable the feature outright.

## Installation
```

git clone https://github.com/SirSobhan0/yawc.git
mkdir -p ~/.config/quickshell/
mv yawc ~/.config/quickshell/
cd ~/.config/quickshell/
cp config.yml.sample config.yml
```

edit the config.yml file to configure behavior

## Usage

Run yawc using Quickshell:

```
qs -c yawc
```

To use a custom configuration file:

```
YAWC_CONFIG=/path/to/custom_config.yml qs -c yawc
```

## Controls

Left / Right Arrows: Scroll through wallpapers

Mouse Wheel: Scroll through wallpapers

Enter / Space / Click: Apply selected wallpaper

Escape: Exit

## Thumbnail Cache

Previews are stored as small JPEGs in `~/.cache/yawc/thumbs`. The cache is keyed on each file's path, modification time, and size, so edited or replaced wallpapers regenerate automatically. It is trimmed oldest-first once it grows past `cache_size_limit_mb`.

Roughly 30KB per wallpaper at the default `thumbnail_height: 256` — a 34-image collection uses about 1MB. Deleting the directory is safe; it simply rebuilds on the next launch.

## Development & Maintenance Status

There will likely be no further development or active maintenance on this project. It is provided as-is for personal use. Feel free to fork and modify it for your own needs.

## License

This project is licensed under the GNU General Public License v3.0 or later (GPL-3.0-or-later). See the [COPYING](COPYING) file for full license terms.
