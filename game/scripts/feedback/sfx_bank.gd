extends RefCounted
## M1-10 反馈层·分层音效（打击感六层之 6 / 射击爽感第 6 层）：
## 开火 / 符纸（弹壳）/ 命中 / 击杀 / 熄灯 / 反噬 六层，运行时合成 16bit PCM，不依赖外部音频资源。
## 这是灰盒占位：正式美术阶段按同一套事件键替换为采样，不改调用方。

const RATE := 22050
const POOL := 10

var _streams: Dictionary = {}
var _players: Array = []
var _next := 0
var _ready := false

func setup(parent: Node, pool: int = POOL) -> void:
	if _ready:
		return
	for i in range(pool):
		var p := AudioStreamPlayer.new()
		p.name = "Sfx%d" % i
		parent.add_child(p)
		_players.append(p)
	_build_all()
	_ready = true

func has_stream(key: String) -> bool:
	return _streams.has(key)

func play(key: String, pitch: float = 1.0, volume_db: float = 0.0) -> void:
	if not _ready or _players.is_empty():
		return
	var st: AudioStreamWAV = _streams.get(key, null)
	if st == null:
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = st
	p.pitch_scale = clampf(pitch, 0.5, 2.0)
	p.volume_db = volume_db
	p.play()

# ------------------------------------------------------------------ 合成

func _build_all() -> void:
	_streams["fire"] = _wav(_mix(
		_noise(0.10, 55.0, 0.45, 0.55),
		_sweep(220.0, 70.0, 0.11, 30.0, 0.75), 1.0, 0.7))
	_streams["casing"] = _wav(_noise(0.035, 160.0, 0.95, 0.5))
	_streams["hit"] = _wav(_mix(
		_sweep(180.0, 62.0, 0.09, 32.0, 0.80),
		_noise(0.06, 95.0, 0.70, 0.50), 1.0, 0.55))
	_streams["kill"] = _wav(_mix(
		_sweep(120.0, 42.0, 0.26, 12.0, 0.90),
		_noise(0.30, 11.0, 0.30, 0.45), 1.0, 0.80))
	_streams["lantern"] = _wav(_mix(
		_sweep(560.0, 180.0, 0.30, 8.0, 0.32),
		_noise(0.25, 14.0, 0.20, 0.25), 1.0, 0.60))
	_streams["backlash"] = _wav(_mix(
		_noise(0.35, 9.0, 0.15, 0.50),
		_sweep(95.0, 48.0, 0.36, 6.0, 0.70), 1.0, 0.90))
	_streams["fizzle"] = _wav(_noise(0.14, 30.0, 0.08, 0.35))

func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var n := samples.size()
	var buf := PackedByteArray()
	buf.resize(n * 2)
	for i in range(n):
		buf.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = buf
	return s

func _noise(dur: float, decay: float, lp: float, gain: float) -> PackedFloat32Array:
	var n := int(dur * float(RATE))
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261121
	var prev := 0.0
	for i in range(n):
		var t := float(i) / float(RATE)
		var white := rng.randf_range(-1.0, 1.0)
		prev += (white - prev) * clampf(lp, 0.01, 1.0)
		out[i] = prev * exp(-t * decay) * gain
	return out

func _sweep(f0: float, f1: float, dur: float, decay: float, gain: float) -> PackedFloat32Array:
	var n := int(dur * float(RATE))
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / float(RATE)
		var f := lerpf(f0, f1, clampf(t / maxf(dur, 0.001), 0.0, 1.0))
		phase += TAU * f / float(RATE)
		out[i] = sin(phase) * exp(-t * decay) * gain
	return out

func _mix(a: PackedFloat32Array, b: PackedFloat32Array, ga: float, gb: float) -> PackedFloat32Array:
	var n := maxi(a.size(), b.size())
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var va := a[i] * ga if i < a.size() else 0.0
		var vb := b[i] * gb if i < b.size() else 0.0
		out[i] = va + vb
	return out
