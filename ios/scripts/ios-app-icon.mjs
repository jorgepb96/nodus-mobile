// Draw the iOS app icon from Desktop's shared geometry and default vault palette.
//
// The desktop rasterises its dock icon from the same numbers (src/dockIcon.ts). Doing it here
// too keeps the glyph and its ink consistent with Desktop. iOS supplies the outer mask.
//
//   node ios/scripts/ios-app-icon.mjs
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { mobileRoot, nodusRepo } from './nodus-repo.mjs';

const repoRoot = mobileRoot;
const mark = JSON.parse(fs.readFileSync(path.join(nodusRepo(), 'shared/nodusMark.json'), 'utf8'));
const palette = fs.readFileSync(path.join(nodusRepo(), 'shared/vaultColors.ts'), 'utf8');
const accent = palette.match(/\bacademic:\s*['"](#[0-9a-f]{6})['"]/i)?.[1];
if (!accent) throw new Error('The canonical Desktop academic accent is required');
// Same white/black mixing and rounding as src/dockIcon.ts.
function shade(color, amount) {
  const channels = color.slice(1).match(/../g).map(value => parseInt(value, 16));
  const target = amount >= 0 ? 255 : 0;
  return '#' + channels.map(value => Math.round(value + (target - value) * Math.abs(amount)).toString(16).padStart(2, '0')).join('');
}
const light = shade(accent, 0.55);
const dark = shade(accent, -0.4);
const outputDir = path.join(repoRoot, 'ios/Nodus/Assets.xcassets/AppIcon.appiconset');

const SIZE = 1024;
const { plateInsetRatio, markScaleRatio,
        strokeWidth, nodeRadius, leftX, rightX, topY, bottomY, gradient } = mark;

// The ink, not the viewBox: the round caps and the corner nodes paint half a stroke past the
// vertices, so fitting the box would leave the glyph small and off-centre inside the plate.
const ink = {
  x: leftX - nodeRadius,
  y: topY - nodeRadius,
  width: (rightX - leftX) + nodeRadius * 2,
  height: (bottomY - topY) + nodeRadius * 2,
};

const plateInset = SIZE * plateInsetRatio;
const plateSize = SIZE - plateInset * 2;

// Fit the ink into the share of the plate the mark is allowed to occupy.
const markBox = plateSize * markScaleRatio;
const scale = Math.min(markBox / ink.width, markBox / ink.height);
const originX = SIZE / 2 - (ink.x + ink.width / 2) * scale;
const originY = SIZE / 2 - (ink.y + ink.height / 2) * scale;
const at = (x, y) => `${(originX + x * scale).toFixed(2)} ${(originY + y * scale).toFixed(2)}`;
const point = (x, y) => ({ x: originX + x * scale, y: originY + y * scale });

const nodes = [
  { x: leftX, y: bottomY, fill: accent },
  { x: leftX, y: topY, fill: light },
  { x: rightX, y: bottomY, fill: shade(accent, -0.15) },
  { x: rightX, y: topY, fill: dark },
];

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">
  <defs>
    <linearGradient id="mark" x1="${point(gradient.x1, gradient.y1).x}" y1="${point(gradient.x1, gradient.y1).y}" x2="${point(gradient.x2, gradient.y2).x}" y2="${point(gradient.x2, gradient.y2).y}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${light}"/>
      <stop offset="0.45" stop-color="${accent}"/>
      <stop offset="1" stop-color="${dark}"/>
    </linearGradient>
  </defs>

  <rect x="0" y="0" width="${SIZE}" height="${SIZE}" fill="#ffffff"/>

  <path d="M ${at(leftX, bottomY)} L ${at(leftX, topY)} L ${at(rightX, bottomY)} L ${at(rightX, topY)}"
        fill="none" stroke="url(#mark)" stroke-width="${(strokeWidth * scale).toFixed(2)}"
        stroke-linecap="round" stroke-linejoin="round"/>
${nodes.map((node) => {
  const centre = point(node.x, node.y);
  return `  <circle cx="${centre.x.toFixed(2)}" cy="${centre.y.toFixed(2)}" r="${(nodeRadius * scale).toFixed(2)}" fill="${node.fill}"/>`;
}).join('\n')}
</svg>
`;

fs.mkdirSync(outputDir, { recursive: true });
const svgPath = path.join(outputDir, 'icon.svg');
fs.writeFileSync(svgPath, svg);

// iOS 18+ wants one 1024 source and derives the rest; a Contents.json that names a single
// universal image is all the asset catalogue needs.
execFileSync('rsvg-convert', ['-w', String(SIZE), '-h', String(SIZE), '-o', path.join(outputDir, 'icon-1024.png'), svgPath]);
fs.unlinkSync(svgPath);

fs.writeFileSync(path.join(outputDir, 'Contents.json'), `${JSON.stringify({
  images: [{ filename: 'icon-1024.png', idiom: 'universal', platform: 'ios', size: '1024x1024' }],
  info: { author: 'xcode', version: 1 },
}, null, 2)}\n`);

// The launch screen follows Desktop's light and dark plates.
const colorsDir = path.join(repoRoot, 'ios/Nodus/Assets.xcassets/LaunchBackground.colorset');
fs.mkdirSync(colorsDir, { recursive: true });
fs.writeFileSync(path.join(colorsDir, 'Contents.json'), `${JSON.stringify({
  colors: [
    {
      color: { 'color-space': 'srgb', components: { alpha: '1.000', blue: '0xFF', green: '0xFF', red: '0xFF' } },
      idiom: 'universal',
    },
    {
      appearances: [{ appearance: 'luminosity', value: 'dark' }],
      color: { 'color-space': 'srgb', components: { alpha: '1.000', blue: '0x17', green: '0x14', red: '0x14' } },
      idiom: 'universal',
    },
  ],
  info: { author: 'xcode', version: 1 },
}, null, 2)}\n`);

fs.writeFileSync(path.join(repoRoot, 'ios/Nodus/Assets.xcassets/Contents.json'), `${JSON.stringify({
  info: { author: 'xcode', version: 1 },
}, null, 2)}\n`);

console.log(`Wrote ${path.relative(repoRoot, path.join(outputDir, 'icon-1024.png'))}`);
