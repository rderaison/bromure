// SF Symbols can't ship outside Apple platforms (license), so every symbol the
// macOS app uses is mapped to its closest Lucide glyph here. Call sites keep the
// SF name — <SF name="folder.fill" /> — so the port reads like the Swift.
//
// Add a mapping when you port a view that uses a new symbol. `.fill` variants
// render with a fill. Unknown names render a small square and warn once in dev.

import React from 'react';
import { icons } from 'lucide-react';

type L = keyof typeof icons;

const MAP: Record<string, L> = {
  'magnifyingglass': 'Search', 'plus': 'Plus', 'minus': 'Minus', 'xmark': 'X', 'xmark.circle.fill': 'CircleX', 'xmark.circle': 'CircleX',
  'checkmark': 'Check', 'checkmark.circle.fill': 'CircleCheck', 'checkmark.circle': 'CircleCheck', 'checkmark.seal.fill': 'BadgeCheck',
  'chevron.right': 'ChevronRight', 'chevron.left': 'ChevronLeft', 'chevron.down': 'ChevronDown', 'chevron.up': 'ChevronUp',
  'chevron.up.chevron.down': 'ChevronsUpDown', 'chevron.left.forwardslash.chevron.right': 'CodeXml',
  'ellipsis': 'Ellipsis', 'ellipsis.circle': 'CircleEllipsis', 'ellipsis.circle.fill': 'Ellipsis',
  'folder': 'Folder', 'folder.fill': 'Folder', 'folder.badge.plus': 'FolderPlus', 'doc': 'File', 'doc.fill': 'File', 'doc.text': 'FileText',
  'doc.on.doc': 'Copy', 'doc.text.magnifyingglass': 'FileSearch', 'doc.badge.gearshape': 'FileCog', 'doc.badge.plus': 'FilePlus',
  'terminal': 'SquareTerminal', 'terminal.fill': 'SquareTerminal', 'apple.terminal': 'SquareTerminal', 'globe': 'Globe', 'network': 'Network',
  'sidebar.left': 'PanelLeft', 'sidebar.right': 'PanelRight', 'sidebar.squares.left': 'PanelLeft',
  'sparkles': 'Sparkles', 'sparkle': 'Sparkle', 'gearshape': 'Settings', 'gearshape.fill': 'Settings', 'gear': 'Settings',
  'bolt.fill': 'Zap', 'bolt': 'Zap', 'shield': 'Shield', 'shield.fill': 'Shield', 'shield.lefthalf.filled': 'ShieldHalf',
  'exclamationmark.shield.fill': 'ShieldExclamationPoint', 'checkmark.shield.fill': 'ShieldCheck', 'lock.shield': 'ShieldCheck', 'lock.shield.fill': 'ShieldCheck',
  'key': 'Key', 'key.fill': 'Key', 'key.horizontal.fill': 'KeyRound', 'flame': 'Flame', 'flame.fill': 'Flame', 'lock': 'Lock', 'lock.fill': 'Lock', 'lock.open': 'LockOpen',
  'person': 'User', 'person.fill': 'User', 'person.crop.circle': 'CircleUser', 'person.2': 'Users', 'person.text.rectangle': 'IdCard',
  'person.crop.rectangle': 'IdCard', 'cpu': 'Cpu', 'memorychip': 'MemoryStick', 'shippingbox': 'Package', 'shippingbox.fill': 'Package', 'cube': 'Box', 'cube.fill': 'Box',
  'arrow.triangle.branch': 'GitBranch', 'arrow.triangle.merge': 'GitMerge', 'arrow.triangle.pull': 'GitPullRequest', 'point.3.connected.trianglepath.dotted': 'Network',
  'play.fill': 'Play', 'play': 'Play', 'play.circle': 'CirclePlay', 'pause.fill': 'Pause', 'pause': 'Pause', 'pause.circle': 'CirclePause', 'stop.fill': 'Square', 'stop.circle': 'CircleStop',
  'arrow.up': 'ArrowUp', 'arrow.down': 'ArrowDown', 'arrow.right': 'ArrowRight', 'arrow.left': 'ArrowLeft', 'arrow.up.right': 'ArrowUpRight',
  'arrow.up.circle.fill': 'CircleArrowUp', 'arrow.clockwise': 'RotateCw', 'arrow.counterclockwise': 'RotateCcw', 'arrow.2.circlepath': 'RefreshCw',
  'arrow.uturn.backward': 'Undo2', 'arrow.down.circle': 'CircleArrowDown', 'arrow.down.to.line': 'ArrowDownToLine', 'arrow.up.to.line': 'ArrowUpToLine',
  'arrow.up.right.square': 'SquareArrowUpRightExit', 'arrow.up.forward.app': 'SquareArrowUpRightExit', 'arrow.right.circle': 'CircleArrowRight',
  'arrow.left.arrow.right': 'ArrowLeftRight', 'arrow.up.arrow.down': 'ArrowUpDown', 'arrow.turn.down.left': 'CornerDownLeft', 'return': 'CornerDownLeft',
  'square.and.arrow.up': 'Share', 'square.and.arrow.down': 'Download', 'square.and.pencil': 'SquarePen', 'pencil': 'Pencil', 'pencil.line': 'PencilLine',
  'trash': 'Trash', 'trash.fill': 'Trash', 'clock': 'Clock', 'clock.fill': 'Clock', 'clock.arrow.circlepath': 'RotateCcwClock', 'timer': 'Timer',
  'bell': 'Bell', 'bell.fill': 'Bell', 'bell.badge': 'BellDot', 'list.bullet': 'List', 'list.bullet.rectangle': 'ListTodo', 'checklist': 'ListChecks',
  'list.bullet.indent': 'ListTree', 'square.grid.2x2': 'LayoutGrid', 'square.grid.2x2.fill': 'LayoutGrid', 'rectangle.split.2x2': 'LayoutGrid',
  'rectangle.3.group': 'LayoutDashboard', 'rectangle.stack': 'Layers', 'square.stack.3d.up': 'Layers', 'square.on.square': 'Copy',
  'desktopcomputer': 'Monitor', 'display': 'Monitor', 'laptopcomputer': 'Laptop', 'server.rack': 'Server', 'externaldrive': 'HardDrive', 'internaldrive': 'HardDrive',
  'antenna.radiowaves.left.and.right': 'RadioTower', 'wifi': 'Wifi', 'wifi.slash': 'WifiOff', 'cloud': 'Cloud', 'icloud': 'Cloud', 'link': 'Link',
  'eye': 'Eye', 'eye.slash': 'EyeOff', 'line.3.horizontal.decrease.circle': 'ListFilter', 'line.3.horizontal.decrease': 'ListFilter', 'line.3.horizontal': 'Menu',
  'info.circle': 'Info', 'info.circle.fill': 'Info', 'exclamationmark.triangle': 'TriangleExclamationPoint', 'exclamationmark.triangle.fill': 'TriangleExclamationPoint',
  'exclamationmark.circle': 'CircleExclamationPoint', 'exclamationmark.circle.fill': 'CircleExclamationPoint', 'exclamationmark.octagon.fill': 'OctagonExclamationPoint', 'questionmark.circle': 'CircleQuestionMark',
  'hammer': 'Hammer', 'hammer.fill': 'Hammer', 'wrench': 'Wrench', 'wrench.and.screwdriver': 'Wrench', 'wrench.and.screwdriver.fill': 'Wrench',
  'calendar': 'Calendar', 'calendar.badge.clock': 'CalendarClock', 'bubble.left': 'MessageSquare', 'bubble.left.and.bubble.right': 'MessagesSquare',
  'text.bubble': 'MessageSquareText', 'paperplane': 'Send', 'paperplane.fill': 'Send', 'mic': 'Mic', 'photo': 'Image', 'paperclip': 'Paperclip',
  'at': 'AtSign', 'number': 'Hash', 'tag': 'Tag', 'star': 'Star', 'star.fill': 'Star', 'bookmark': 'Bookmark',
  'power': 'Power', 'restart': 'RotateCw', 'moon': 'Moon', 'moon.stars.fill': 'MoonStar', 'moon.fill': 'Moon', 'sun.max': 'Sun', 'circle': 'Circle', 'circle.fill': 'Circle',
  'circle.dashed': 'CircleDashed', 'circle.lefthalf.filled': 'CircleDot', 'square': 'Square', 'square.fill': 'Square', 'rectangle': 'RectangleHorizontal',
  'scissors': 'Scissors', 'wand.and.stars': 'WandSparkles', 'brain': 'Brain', 'brain.head.profile': 'Brain', 'atom': 'Atom', 'puzzlepiece': 'Puzzle', 'puzzlepiece.extension': 'Puzzle',
  'puzzlepiece.extension.fill': 'Puzzle', 'curlybraces': 'Braces', 'chart.bar': 'ChartColumn', 'chart.bar.fill': 'ChartColumn', 'chart.xyaxis.line': 'ChartLine',
  'waveform': 'AudioWaveform', 'waveform.path.ecg': 'Activity', 'gauge': 'Gauge', 'speedometer': 'Gauge', 'hand.raised': 'Hand', 'hand.raised.fill': 'Hand',
  'nosign': 'Ban', 'slash.circle': 'Ban', 'trash.slash': 'Trash', 'archivebox': 'Archive', 'archivebox.fill': 'Archive', 'tray': 'Inbox', 'tray.full': 'Inbox',
  'square.split.2x1': 'Columns2', 'rectangle.split.3x1': 'Columns3', 'arrow.down.right.and.arrow.up.left': 'Minimize2', 'arrow.up.left.and.arrow.down.right': 'Maximize2',
  'keyboard': 'Keyboard', 'command': 'Command', 'option': 'Option', 'person.badge.key': 'UserRoundKey', 'theatermasks': 'Drama', 'eyedropper': 'Pipette',
  'paintpalette': 'Palette', 'paintpalette.fill': 'Palette', 'swatchpalette': 'Palette', 'macwindow': 'AppWindow', 'app': 'AppWindow', 'app.badge': 'AppWindow',
  'switch.2': 'ToggleLeft', 'slider.horizontal.3': 'SlidersHorizontal', 'tuningfork': 'Settings2', 'map': 'Map', 'location': 'MapPin', 'building.2': 'Building',
  'envelope': 'Mail', 'phone': 'Phone', 'creditcard': 'CreditCard', 'person.crop.circle.badge.exclamationmark': 'UserX', 'figure.walk': 'Footprints',
  'questionmark': 'CircleQuestionMark', 'lightbulb': 'Lightbulb', 'leaf': 'Leaf', 'ant': 'Bug', 'ladybug': 'Bug', 'testtube.2': 'TestTubes', 'books.vertical': 'Library',
  'text.alignleft': 'TextAlignStart', 'text.magnifyingglass': 'TextSearch', 'textformat': 'Type', 'arrow.right.square': 'SquareArrowRight', 'rectangle.portrait.and.arrow.right': 'LogOut',
  'person.crop.circle.badge.checkmark': 'UserCheck', 'checkmark.rectangle': 'SquareCheck', 'list.number': 'ListOrdered', 'scope': 'Crosshair', 'target': 'Target',
  'stopwatch': 'Timer', 'hourglass': 'Hourglass', 'arrow.triangle.2.circlepath': 'RefreshCw', 'dot.radiowaves.left.and.right': 'Radio', 'bolt.horizontal': 'Zap',
  'rectangle.and.text.magnifyingglass': 'ScanSearch', 'shield.checkered': 'ShieldCheck', 'hand.thumbsup': 'ThumbsUp', 'hand.thumbsdown': 'ThumbsDown',
  // terminals & rooms
  'chart.bar.xaxis': 'ChartNoAxesColumn', 'wand.and.rays': 'WandSparkles', 'pause.circle.fill': 'CirclePause',
  'square.and.arrow.up.on.square': 'Share2', 'personalhotspot': 'Link2', 'minus.circle': 'CircleMinus', 'square.dashed.inset.filled': 'SquareDashed', 'cable.connector': 'Cable', 'powerplug': 'Plug', 'sun.min': 'Sun',
  'quote.bubble': 'MessageSquareQuote', 'arrow.up.right.circle.fill': 'CircleArrowUpRightExit', 'xmark.shield.fill': 'ShieldX',
  // connect, palette & new session
  'text.bubble.fill': 'MessageSquareText', 'bolt.badge.clock.fill': 'Zap', 'macmini': 'HardDrive', 'macmini.fill': 'HardDrive',
  'wifi.exclamationmark': 'WifiOff', 'person.crop.circle.badge.plus': 'UserRoundPlus', 'arrow.down.doc': 'FileDown',
  // sidebar & toolbar
  'bolt.badge.clock': 'Zap', 'shield.slash.fill': 'ShieldOff', 'helm': 'ShipWheel',
  'key.slash': 'KeyRound', 'exclamationmark.shield': 'ShieldExclamationPoint', 'arrow.clockwise.circle': 'RotateCw', 'bolt.circle': 'Zap',
  'doc.richtext': 'FileText', 'network.badge.shield.half.filled': 'ShieldHalf', 'point.3.filled.connected.trianglepath.dotted': 'Network',
  // trace inspector
  'arrow.up.doc': 'FileUp', 'tray.and.arrow.down': 'Inbox', 'xmark.octagon.fill': 'OctagonX',
  // session stage / chat
  'questionmark.bubble.fill': 'MessageCircleQuestionMark', 'line.3.horizontal.decrease.circle.fill': 'ListFilter',
  'arrow.up.circle': 'CircleArrowUp', 'questionmark.folder': 'FolderSearch', 'gauge.with.dots.needle.33percent': 'Gauge',
  // editor: machine panes
  'person.badge.key.fill': 'UserKey', 'arrow.up.doc.fill': 'FileUp', 'arrow.down.doc.fill': 'FileDown', 'video.fill': 'Video', 'mic.fill': 'Mic', 'house.fill': 'House', 'internaldrive.fill': 'HardDrive',
  // editor › Credentials / Guardrails
  'shield.slash': 'ShieldOff', 'cylinder.split.1x2.fill': 'Database', 'cloud.fill': 'Cloud', 'phone.fill': 'Phone', 'line.diagonal': 'Slash',
  'ellipsis.curlybraces': 'Braces', 'cat.fill': 'Cat', 'fox.fill': 'Squirrel', 'cube.box.fill': 'Box', 'key.radiowaves.forward': 'KeySquare',
  'key.radiowaves.forward.fill': 'KeySquare', 'key.viewfinder': 'ScanLine',
  // boards: coding tasks + automations
  'arrow.turn.down.right': 'CornerDownRight', 'arrowshape.turn.up.left.fill': 'Reply', 'checkmark.shield': 'ShieldCheck', 'doc.questionmark': 'FileQuestionMark',
  'exclamationmark.bubble.fill': 'MessageSquareDot', 'forward.end': 'SkipForward', 'pencil.circle.fill': 'SquarePen', 'person.crop.circle.fill': 'CircleUser',
  'person.fill.checkmark': 'UserCheck', 'plus.circle': 'CirclePlus', 'plus.circle.fill': 'CirclePlus', 'point.topleft.down.to.point.bottomright.curvepath': 'GitCommitHorizontal',
  'tray.full.fill': 'Inbox', 'exclamationmark': 'CircleExclamationPoint',
  // machines: dashboards, files pane, branches, review
  'bolt.horizontal.circle': 'Unplug', 'bubble.left.fill': 'MessageSquare', 'checkmark.bubble': 'MessageSquareCheck', 'checkmark.seal': 'BadgeCheck',
  'checkmark.square.fill': 'SquareCheck', 'circle.grid.cross': 'Crosshair', 'cpu.fill': 'Cpu', 'doc.plaintext': 'FileText',
  'externaldrive.badge.icloud': 'HardDriveUpload', 'externaldrive.connected.to.line.below': 'HardDriveDownload', 'externaldrive.fill': 'HardDrive',
  'externaldrive.fill.badge.plus': 'HardDrive', 'folder.badge.questionmark': 'FolderSearch', 'memorychip.fill': 'MemoryStick',
  'minus.circle.fill': 'CircleMinus', 'moon.zzz': 'Moon', 'person.2.fill': 'Users', 'play.circle.fill': 'CirclePlay', 'plus.bubble': 'MessageSquarePlus',
  'plus.bubble.fill': 'MessageSquarePlus', 'plus.square.dashed': 'SquareDashed', 'point.topleft.down.curvedto.point.bottomright.up': 'GitCommitHorizontal',
  'shippingbox.and.arrow.backward': 'PackageOpen', 'square.stack.3d.up.fill': 'Layers',
  'cube.transparent.fill': 'Box', 'building.columns.fill': 'Landmark', 'doc.text.fill': 'FileText', 'scroll': 'Scroll', 'arrow.up.forward.square': 'SquareArrowUpRight', 'person.crop.circle.badge.questionmark': 'UserRoundSearch',
};

const FILLED = /\.fill$/;
const warned = new Set<string>();

export function SF({ name, size = 14, weight = 400, color, style, className }: {
  name: string; size?: number; weight?: number; color?: string; style?: React.CSSProperties; className?: string;
}) {
  const key = MAP[name];
  if (!key) {
    if (import.meta.env?.DEV && !warned.has(name)) { warned.add(name); console.warn('SF symbol not mapped:', name); }
    return <span className={className} style={{ display: 'inline-block', width: size, height: size, ...style }} />;
  }
  const Icon = icons[key];
  // SF Symbol weights → stroke: regular ≈ 1.6 at 14pt, semibold ≈ 2.1.
  const stroke = weight >= 700 ? 2.6 : weight >= 600 ? 2.2 : weight >= 500 ? 1.9 : 1.6;
  const fill = FILLED.test(name) && !/^(xmark|checkmark|exclamationmark|info|arrow|play|pause|stop)/.test(name) ? 'currentColor' : 'none';
  return <Icon size={size} strokeWidth={stroke} color={color} fill={fill} className={className}
               style={{ flexShrink: 0, display: 'inline-block', verticalAlign: 'middle', ...style }} />;
}

export function hasSymbol(name: string) { return name in MAP; }
