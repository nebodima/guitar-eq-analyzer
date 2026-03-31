#!/usr/bin/env python3
"""
Guitar EQ Analyzer
— Спектр в реальном времени (mic или файл)
— 7-полосный параметрический эквалайзер
— Воспроизведение с применением EQ
— Сохранение настроек EQ
"""

import numpy as np
import sounddevice as sd
import soundfile as sf
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from matplotlib.widgets import Button, Slider
from matplotlib.ticker import FixedLocator, FuncFormatter
from scipy.signal import sosfilt, sosfilt_zi
from datetime import datetime
import subprocess, tempfile, os, threading, sys, json, atexit, fcntl, time

# ─── Параметры ───────────────────────────────────────────────
SAMPLE_RATE   = 44100
BLOCK_SIZE    = 4096
FREQ_MIN      = 60
FREQ_MAX      = 8000
SMOOTHING     = 0.75
Y_MIN_DB      = -110
Y_MAX_DB      = -40
EQ_CURVE_BASELINE_DB = -92

# Полосы EQ (Гц)
EQ_FREQS = [80, 200, 400, 800, 1600, 3200, 6400]
EQ_Q     = 1.4   # добротность (bandwidth ~0.7 октавы)
EQ_RANGE = 12.0  # ±dB
DEFAULT_EQ_GAINS = [-6.0, -5.0, -3.0, +1.0, +2.5, +2.5, +0.5]
EQ_SAVE_PATH = os.path.join(os.path.dirname(__file__), "eq_saved.json")
LOG_PATH = os.path.join(os.path.dirname(__file__), "guitar_eq_live.log")
LOG_INTERVAL_SEC = 0.5
FIG_WIDTH_PX = 1200
FIG_HEIGHT_PX = 760
OUTPUT_GAIN_DB = -9.0
OUTPUT_GAIN = 10 ** (OUTPUT_GAIN_DB / 20.0)
HOT_DIFF_DB = 5.0
HOT_ABS_LEVEL_DB = -72.0
AUTO_EQ_UPDATE_SEC = 0.7
AUTO_EQ_MAX_STEP_DB = 0.20
AUTO_EQ_STRENGTH = 0.20
AUTO_EQ_TARGET_REL_DB = np.array([-0.9, -0.5, -0.2, 0.0, 0.2, 0.2, -0.1], dtype=float)
AUTO_EQ_MIN_MEDIAN_DB = -95.0
AUTO_EQ_MIN_CHANGE_DB = 0.01
AUTO_EQ_ABS_LIMIT_DB = 8.0
AUTO_EQ_DAMPING = 0.10
AUTO_EQ_BAND_RESPONSE = np.array([0.9, 0.9, 0.8, 0.7, 0.45, 0.30, 0.20], dtype=float)
# Гитарный профиль: низ (80 Гц) держим существенно ниже,
# 200/400 не режем чрезмерно, чтобы не убить тело инструмента.
AUTO_EQ_BAND_MIN_DB = np.array([-12.0, -6.0, -5.0, -3.5, 0.0, 0.0, -1.0], dtype=float)
AUTO_EQ_BAND_MAX_DB = np.array([-4.0, -1.0, -0.5, +2.0, +3.5, +2.6, +2.5], dtype=float)
AUTO_EQ_REF_ALPHA = 0.08
AUTO_EQ_HIGH_PENALTY_THRESHOLD_DB = 2.0
AUTO_EQ_HIGH_PENALTY_STRENGTH = 0.20

_instance_lock = None
last_log_time = 0.0
last_auto_eq_time = 0.0
auto_eq_err_smooth = np.zeros(len(EQ_FREQS), dtype=float)
auto_eq_ref_rel = None
original_hold_spec = None
original_hold_freqs = None
original_hold_enabled = False

def init_live_log():
    """Инициализировать live-лог для мониторинга."""
    with open(LOG_PATH, "w", encoding="utf-8") as fp:
        fp.write(f"# Guitar EQ live log started at {datetime.now().isoformat()}\n")
        fp.write("# ts mode peak_hz peak_db max_amp eq_gains_db\n")

def write_live_log(peak_hz, peak_db, max_amp):
    """Писать текущие параметры в live-лог с ограничением частоты."""
    global last_log_time
    now = time.monotonic()
    if now - last_log_time < LOG_INTERVAL_SEC:
        return
    last_log_time = now

    gains = ", ".join(f"{f}:{g:+.1f}dB" for f, g in zip(EQ_FREQS, eq_gains))
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    eq_state = "on" if eq_enabled else "off"
    auto_eq_state = "on" if auto_eq_enabled else "off"
    line = (
        f"{ts} mode={mode} eq_state={eq_state} auto_eq={auto_eq_state} peak_hz={peak_hz:.1f} "
        f"peak_db={peak_db:.1f} max_amp={max_amp:.3f} eq=[{gains}]"
    )
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as fp:
            fp.write(line + "\n")
    except Exception:
        # Лог не должен мешать работе UI и аудио.
        pass

def acquire_single_instance_lock():
    """Запретить запуск второй копии программы."""
    global _instance_lock
    lock_path = "/tmp/guitar_eq_analyzer.lock"
    _instance_lock = open(lock_path, "w")
    try:
        fcntl.flock(_instance_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("[Error] Guitar EQ Analyzer уже запущен. Закрой первую копию.")
        sys.exit(1)
    _instance_lock.write(str(os.getpid()))
    _instance_lock.flush()
    atexit.register(_instance_lock.close)

acquire_single_instance_lock()
init_live_log()

# ─── Параметрический EQ (biquad peaking) ─────────────────────
def peaking_sos(f0, gain_db, Q, fs):
    """Audio EQ Cookbook: peaking EQ biquad as SOS."""
    if abs(gain_db) < 0.05:
        # bypass — единичный фильтр
        return np.array([[1, 0, 0, 1, 0, 0]], dtype=float)
    A  = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * f0 / fs
    alpha = np.sin(w0) / (2 * Q)
    b0 =  1 + alpha * A
    b1 = -2 * np.cos(w0)
    b2 =  1 - alpha * A
    a0 =  1 + alpha / A
    a1 = -2 * np.cos(w0)
    a2 =  1 - alpha / A
    return np.array([[b0/a0, b1/a0, b2/a0, 1, a1/a0, a2/a0]])

def format_freq_label(freq_hz):
    """Удобный формат частот для осей/подписей полос."""
    if freq_hz >= 1000:
        k = freq_hz / 1000.0
        return f"{k:.1f}k" if abs(k - round(k)) > 1e-9 else f"{int(k)}k"
    return f"{int(freq_hz)}"

def load_saved_eq_gains():
    """Загрузить ранее сохраненный пресет из фиксированного файла."""
    try:
        if not os.path.exists(EQ_SAVE_PATH):
            return DEFAULT_EQ_GAINS.copy()
        with open(EQ_SAVE_PATH, "r", encoding="utf-8") as fp:
            data = json.load(fp)
        gains = []
        for f in EQ_FREQS:
            key = f"{f}Hz"
            gains.append(float(data.get(key, 0.0)))
        arr = np.clip(np.array(gains, dtype=float), -EQ_RANGE, EQ_RANGE)
        return arr.tolist()
    except Exception:
        return DEFAULT_EQ_GAINS.copy()

def query_input_devices():
    """Список доступных входных устройств sounddevice."""
    devices = []
    try:
        for idx, dev in enumerate(sd.query_devices()):
            if int(dev.get("max_input_channels", 0)) > 0:
                devices.append({"id": idx, "name": str(dev.get("name", f"Input {idx}"))})
    except Exception:
        return []
    return devices

def short_device_name(name, max_len=22):
    s = " ".join(name.split())
    if len(s) <= max_len:
        return s
    return s[:max_len-1] + "…"

def eq_freq_response(gains_db, freqs_plot):
    """Суммарная АЧХ цепочки EQ на заданных частотах."""
    H_total = np.ones(len(freqs_plot), dtype=complex)
    for f0, g in zip(EQ_FREQS, gains_db):
        sos = peaking_sos(f0, g, EQ_Q, SAMPLE_RATE)
        b   = sos[0, :3]
        a   = sos[0, 3:]
        a[0] = 1.0  # нормировка уже в sos
        w = 2 * np.pi * freqs_plot / SAMPLE_RATE
        ejw = np.exp(-1j * w)
        num = b[0] + b[1]*ejw + b[2]*ejw**2
        den = a[0] + a[1]*ejw + a[2]*ejw**2
        H_total *= num / den
    return 20 * np.log10(np.abs(H_total) + 1e-10)

# ─── Состояние ───────────────────────────────────────────────
audio_buffer    = np.zeros(BLOCK_SIZE, dtype=np.float32)
analysis_buffer = np.zeros(BLOCK_SIZE, dtype=np.float32)  # вход до EQ
spectrum_smooth = None
analysis_smooth = None
mode            = 'idle'  # 'mic' | 'file' | 'idle'
file_position   = 0
file_data       = None
last_file_name  = ""
play_stream     = None
mic_stream_ref  = [None]
ui_events       = []

eq_gains = load_saved_eq_gains()   # текущие усиления полос
eq_enabled = True
auto_eq_enabled = False
input_devices = query_input_devices()
selected_input_idx = 0
if input_devices:
    try:
        default_in = sd.default.device[0] if isinstance(sd.default.device, (tuple, list)) else int(sd.default.device)
        for i, d in enumerate(input_devices):
            if d["id"] == default_in:
                selected_input_idx = i
                break
    except Exception:
        pass

# Состояние фильтров (zi) для каждой полосы
eq_zi = [None] * len(EQ_FREQS)

def stop_play_stream():
    """Остановить и закрыть поток воспроизведения файла."""
    global play_stream
    if play_stream is None:
        return
    try:
        play_stream.stop()
    except Exception:
        pass
    try:
        play_stream.close()
    except Exception:
        pass
    play_stream = None

def start_mic_stream():
    """Запустить поток микрофона, если он не запущен."""
    if mic_stream_ref[0] is not None:
        return
    dev_id = None
    if input_devices and 0 <= selected_input_idx < len(input_devices):
        dev_id = input_devices[selected_input_idx]["id"]
    mic_stream_ref[0] = sd.InputStream(
        samplerate=SAMPLE_RATE,
        blocksize=int(BLOCK_SIZE * 0.25),
        channels=1,
        device=dev_id,
        callback=audio_callback,
        dtype='float32'
    )
    mic_stream_ref[0].start()

def stop_mic_stream():
    """Полностью остановить и закрыть поток микрофона."""
    stream = mic_stream_ref[0]
    if stream is None:
        return
    try:
        stream.stop()
    except Exception:
        pass
    try:
        stream.close()
    except Exception:
        pass
    mic_stream_ref[0] = None

def reset_eq_zi():
    global eq_zi
    eq_zi = [None] * len(EQ_FREQS)

def apply_eq(chunk):
    """Применяет EQ к блоку аудио, сохраняя состояние фильтров."""
    global eq_zi
    if not eq_enabled:
        return chunk
    out = chunk.copy()
    for i, (f0, g) in enumerate(zip(EQ_FREQS, eq_gains)):
        if abs(g) < 0.05:
            eq_zi[i] = None
            continue
        sos = peaking_sos(f0, g, EQ_Q, SAMPLE_RATE)
        if eq_zi[i] is None:
            eq_zi[i] = sosfilt_zi(sos) * out[0] if len(out) > 0 else sosfilt_zi(sos)
        out, eq_zi[i] = sosfilt(sos, out, zi=eq_zi[i])
    return out

# ─── Аудио коллбэки ──────────────────────────────────────────
def audio_callback(indata, frames, time, status):
    global audio_buffer, analysis_buffer
    if mode != 'mic':
        return
    mono = indata[:, 0] if indata.ndim > 1 else indata.flatten()
    audio_buffer = np.roll(audio_buffer, -len(mono))
    audio_buffer[-len(mono):] = mono
    analysis_buffer = np.roll(analysis_buffer, -len(mono))
    analysis_buffer[-len(mono):] = mono

def file_callback(outdata, frames, time, status):
    global audio_buffer, analysis_buffer, file_position
    if file_data is None or len(file_data) == 0:
        outdata[:, 0] = np.zeros(frames, dtype=np.float32)
        return

    end = file_position + frames
    if end <= len(file_data):
        chunk = file_data[file_position:end]
        file_position = end % len(file_data)
    else:
        first = file_data[file_position:]
        remain = frames - len(first)
        second = file_data[:remain]
        chunk = np.concatenate((first, second)).astype(np.float32, copy=False)
        file_position = remain

    # Буфер для анализа AutoEQ: исходник ДО эквализации.
    analysis_buffer = np.roll(analysis_buffer, -frames)
    analysis_buffer[-frames:] = chunk

    # Применяем EQ
    eq_chunk = apply_eq(chunk.copy())
    # Мастер-гейн с запасом, чтобы не было перегрома на выходе.
    eq_chunk = eq_chunk * OUTPUT_GAIN
    eq_chunk = np.clip(eq_chunk, -1.0, 1.0)
    outdata[:, 0] = eq_chunk
    # Буфер анализатора — после EQ
    audio_buffer = np.roll(audio_buffer, -frames)
    audio_buffer[-frames:] = eq_chunk

def start_file_playback(reset_position=True):
    """Запустить воспроизведение уже загруженного файла."""
    global mode, file_position, play_stream
    if file_data is None or len(file_data) == 0:
        return False
    stop_play_stream()
    stop_mic_stream()
    if reset_position:
        file_position = 0
    mode = 'file'
    reset_eq_zi()
    play_stream = sd.OutputStream(
        samplerate=SAMPLE_RATE, blocksize=512,
        channels=1, callback=file_callback, dtype='float32'
    )
    play_stream.start()
    return True

# ─── Работа с файлом ─────────────────────────────────────────
def decode_to_wav(path):
    tmp = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)
    tmp.close()
    subprocess.run(
        ['ffmpeg', '-y', '-i', path, '-ac', '1', '-ar', str(SAMPLE_RATE), tmp.name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True
    )
    return tmp.name

def load_audio_file(path):
    global file_data, file_position, mode, play_stream, last_file_name
    ext    = os.path.splitext(path)[1].lower()
    native = {'.wav', '.flac', '.aif', '.aiff', '.ogg', '.opus'}
    try:
        if ext not in native:
            print(f"[ffmpeg] {ext} -> WAV...")
            tmp  = decode_to_wav(path)
            data, sr = sf.read(tmp, dtype='float32')
            os.unlink(tmp)
        else:
            data, sr = sf.read(path, dtype='float32')

        if data.ndim > 1:
            data = data[:, 0]
        if sr != SAMPLE_RATE:
            n    = int(len(data) * SAMPLE_RATE / sr)
            data = np.interp(np.linspace(0, len(data)-1, n),
                             np.arange(len(data)), data).astype('float32')

        file_data     = data
        file_position = 0
        started = start_file_playback(reset_position=True)
        if not started:
            raise RuntimeError("Не удалось запустить воспроизведение файла")

        name = os.path.basename(path)
        last_file_name = name
        ui_events.append(('file_loaded', name[:50]))
        print(f"[File] {name}  |  {len(data)/SAMPLE_RATE:.1f} sec")

    except Exception as e:
        ui_events.append(('file_error', str(e)))
        print(f"[Error] {e}")

def switch_to_mic():
    global mode
    stop_play_stream()
    mode = 'mic'
    start_mic_stream()
    file_label.set_text('')
    reset_eq_zi()
    update_source_buttons()
    fig.canvas.draw_idle()
    print("[MIC] switched to microphone")

def switch_to_idle():
    """Полностью выключить микрофон и воспроизведение файла."""
    global mode, spectrum_smooth, analysis_smooth
    stop_play_stream()
    stop_mic_stream()
    mode = 'idle'
    audio_buffer.fill(0.0)
    analysis_buffer.fill(0.0)
    spectrum_smooth = None
    analysis_smooth = None
    update_source_buttons()
    fig.canvas.draw_idle()
    print("[MIC] disabled")

def pick_file_osascript():
    script = (
        'POSIX path of (choose file with prompt "Выбери аудиофайл" '
        'of type {"public.audio", "com.microsoft.waveform-audio", "public.mp3", "public.aiff-audio"})'
    )
    r = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
    p = r.stdout.strip()
    return p if p else None

# ─── FFT ─────────────────────────────────────────────────────
def compute_spectrum(buffer):
    window  = np.hanning(len(buffer))
    fft     = np.abs(np.fft.rfft(buffer * window)) / len(buffer)
    fft_db  = 20 * np.log10(fft + 1e-10)
    freqs   = np.fft.rfftfreq(len(buffer), 1 / SAMPLE_RATE)
    mask    = (freqs >= FREQ_MIN) & (freqs <= FREQ_MAX)
    return freqs[mask], fft_db[mask]

# ─── Layout ──────────────────────────────────────────────────
n_bands   = len(EQ_FREQS)
fig_dpi   = float(plt.rcParams.get("figure.dpi", 100))
fig       = plt.figure(figsize=(FIG_WIDTH_PX / fig_dpi, FIG_HEIGHT_PX / fig_dpi), dpi=fig_dpi)
fig.patch.set_facecolor('#0e0e0e')

# Верхний: спектр
ax = fig.add_axes([0.07, 0.42, 0.90, 0.52])
ax.set_facecolor('#0e0e0e')

# Слайдеры EQ (внизу)
slider_axes = []
slider_w = 0.80 / n_bands
slider_h = 0.22
for i in range(n_bands):
    sax = fig.add_axes([0.08 + i * slider_w, 0.10, slider_w * 0.7, slider_h])
    sax.set_facecolor('#111111')
    slider_axes.append(sax)

# Кнопки
ax_mic  = fig.add_axes([0.84, 0.71, 0.12, 0.05])
ax_file = fig.add_axes([0.19, 0.02, 0.12, 0.06])
ax_fstp = fig.add_axes([0.33, 0.02, 0.11, 0.06])
ax_snap = fig.add_axes([0.45, 0.02, 0.10, 0.06])
ax_aeqt = fig.add_axes([0.67, 0.02, 0.10, 0.06])
ax_eqtg = fig.add_axes([0.84, 0.89, 0.12, 0.05])
ax_flat = fig.add_axes([0.87, 0.02, 0.06, 0.06])
ax_esav = fig.add_axes([0.84, 0.83, 0.12, 0.05])
ax_olck = fig.add_axes([0.84, 0.77, 0.12, 0.05])
ax_idev = fig.add_axes([0.84, 0.65, 0.12, 0.05])

# ─── Спектр: линии ───────────────────────────────────────────
freqs_init, spec_init = compute_spectrum(audio_buffer)
line_live, = ax.plot(freqs_init, spec_init, color='#00ff88', lw=1.2, label='Processed (post-EQ)')
line_src,  = ax.plot(freqs_init, spec_init, color='#44aaff', lw=1.1, alpha=0.9, label='Original (pre-EQ, gain-matched)')
line_snap, = ax.plot([], [], color='#ff6644', lw=1.5, ls='--', alpha=0.85, label='Snapshot')

# Линия АЧХ EQ
f_eq_plot  = np.logspace(np.log10(FREQ_MIN), np.log10(FREQ_MAX), 500)
eq_response = eq_freq_response(eq_gains, f_eq_plot)
line_eq,   = ax.plot(f_eq_plot, eq_response + EQ_CURVE_BASELINE_DB, color='#ffcc00', lw=1.5,
                     ls='-', alpha=0.85, label='EQ curve (смещена)')

# Красные зоны перегрузок (будем обновлять)
hotspans = []

ax.set_xlim(FREQ_MIN, FREQ_MAX)
ax.set_ylim(Y_MIN_DB, Y_MAX_DB)
ax.set_xscale('log')
ax.xaxis.set_major_locator(FixedLocator(EQ_FREQS))
ax.xaxis.set_major_formatter(FuncFormatter(lambda x, pos: format_freq_label(x)))
ax.set_xlabel('Frequency, Hz', color='#aaaaaa', fontsize=9)
ax.set_ylabel('Amplitude, dB', color='#aaaaaa', fontsize=9)
ax.set_title('Guitar EQ Analyzer', color='white', fontsize=13)
ax.tick_params(colors='#888888')
ax.grid(True, which='both', color='#2a2a2a', linewidth=0.5)
ax.legend(loc='lower right', facecolor='#1a1a1a', labelcolor='white',
          edgecolor='#444', fontsize=8)

peak_text  = ax.text(0.02, 0.96, '', transform=ax.transAxes,
                     color='#00ff88', fontsize=9, va='top',
                     bbox=dict(boxstyle='round', fc='#111', ec='#00ff88', alpha=0.8))
file_label = ax.text(0.50, 0.96, '', transform=ax.transAxes,
                     color='#aaaaaa', fontsize=8, va='top', ha='center')
clip_text  = ax.text(0.98, 0.04, '', transform=ax.transAxes,
                     color='#00aa44', fontsize=8, ha='right',
                     bbox=dict(boxstyle='round', fc='#111', ec='#00aa44', alpha=0.8))
input_text = ax.text(0.98, 0.96, '', transform=ax.transAxes,
                     color='#8ec8ff', fontsize=7, ha='right', va='top')

# ─── EQ Слайдеры ─────────────────────────────────────────────
sliders = []
for i, (sax, f0) in enumerate(zip(slider_axes, EQ_FREQS)):
    label = f'{format_freq_label(f0)}Hz'
    sl = Slider(
        sax, label, -EQ_RANGE, EQ_RANGE, valinit=eq_gains[i],
        orientation='vertical',
                color='#00aa66', initcolor='none')
    sl.label.set_color('#aaaaaa')
    sl.label.set_fontsize(8)
    sl.valtext.set_color('#00ffaa')
    sl.valtext.set_fontsize(7)
    sliders.append(sl)

def on_slider_change(val):
    global eq_gains
    eq_gains = [s.val for s in sliders]
    reset_eq_zi()
    refresh_eq_curve()

def refresh_eq_curve():
    """Обновить видимую кривую EQ с учетом bypass."""
    if eq_enabled:
        resp = eq_freq_response(eq_gains, f_eq_plot)
    else:
        resp = np.zeros_like(f_eq_plot, dtype=float)
    line_eq.set_ydata(resp + EQ_CURVE_BASELINE_DB)

for sl in sliders:
    sl.on_changed(on_slider_change)

# ─── Кнопки ──────────────────────────────────────────────────
btn_mic  = Button(ax_mic,  'MIC',         color='#00aa44', hovercolor='#00cc55')
btn_file = Button(ax_file, 'Open File...', color='#1a1a3a', hovercolor='#2a2a5a')
btn_fstp = Button(ax_fstp, 'Stop File',   color='#333333', hovercolor='#555555')
btn_snap = Button(ax_snap, 'Snapshot',    color='#3a2a00', hovercolor='#5a4400')
btn_aeqt = Button(ax_aeqt, 'AutoEQ OFF', color='#444444', hovercolor='#666666')
btn_eqtg = Button(ax_eqtg, 'EQ ON',      color='#0066aa', hovercolor='#2288cc')
btn_flat = Button(ax_flat, 'Reset',       color='#2a1a2a', hovercolor='#442244')
btn_esav = Button(ax_esav, 'Save EQ',    color='#1a2a3a', hovercolor='#2a4a5a')
btn_olck = Button(ax_olck, 'Orig LIVE',  color='#224466', hovercolor='#335577')
btn_idev = Button(ax_idev, 'Input Dev',  color='#173349', hovercolor='#28506e')
for b in (btn_mic, btn_file, btn_fstp, btn_snap, btn_aeqt, btn_eqtg, btn_flat, btn_esav, btn_olck, btn_idev):
    b.label.set_color('white')
    b.label.set_fontsize(9)

def update_source_buttons():
    if mode == 'mic':
        ax_mic.set_facecolor('#00aa44');  btn_mic.color = '#00aa44'
        btn_mic.label.set_text('MIC ON')
        ax_file.set_facecolor('#1a1a3a'); btn_file.color = '#1a1a3a'
        ax_fstp.set_facecolor('#333333'); btn_fstp.color = '#333333'
        btn_fstp.label.set_text('Play File')
    elif mode == 'file':
        ax_mic.set_facecolor('#1a3a1a');  btn_mic.color = '#1a3a1a'
        btn_mic.label.set_text('MIC OFF')
        ax_file.set_facecolor('#0044aa'); btn_file.color = '#0044aa'
        ax_fstp.set_facecolor('#aa3322'); btn_fstp.color = '#aa3322'
        btn_fstp.label.set_text('Stop File')
    else:
        ax_mic.set_facecolor('#555555');  btn_mic.color = '#555555'
        btn_mic.label.set_text('MIC OFF')
        ax_file.set_facecolor('#1a1a3a'); btn_file.color = '#1a1a3a'
        if file_data is not None and len(file_data) > 0:
            ax_fstp.set_facecolor('#007744'); btn_fstp.color = '#007744'
            btn_fstp.label.set_text('Play File')
        else:
            ax_fstp.set_facecolor('#333333'); btn_fstp.color = '#333333'
            btn_fstp.label.set_text('Play File')

update_source_buttons()

def update_eq_toggle_button():
    if eq_enabled:
        btn_eqtg.label.set_text('EQ ON')
        ax_eqtg.set_facecolor('#0066aa')
        btn_eqtg.color = '#0066aa'
    else:
        btn_eqtg.label.set_text('EQ OFF')
        ax_eqtg.set_facecolor('#555555')
        btn_eqtg.color = '#555555'

update_eq_toggle_button()

def update_auto_eq_button():
    if auto_eq_enabled:
        btn_aeqt.label.set_text('AutoEQ ON')
        ax_aeqt.set_facecolor('#007744')
        btn_aeqt.color = '#007744'
    else:
        btn_aeqt.label.set_text('AutoEQ OFF')
        ax_aeqt.set_facecolor('#444444')
        btn_aeqt.color = '#444444'

update_auto_eq_button()

def update_original_hold_button():
    if original_hold_enabled:
        btn_olck.label.set_text('Orig HOLD')
        ax_olck.set_facecolor('#664400')
        btn_olck.color = '#664400'
    else:
        btn_olck.label.set_text('Orig LIVE')
        ax_olck.set_facecolor('#224466')
        btn_olck.color = '#224466'

update_original_hold_button()

def update_input_device_ui():
    if not input_devices:
        btn_idev.label.set_text('No Input')
        ax_idev.set_facecolor('#555555')
        btn_idev.color = '#555555'
        input_text.set_text('IN: unavailable')
        return
    dev = input_devices[selected_input_idx]
    btn_idev.label.set_text(short_device_name(dev['name'], max_len=14))
    ax_idev.set_facecolor('#173349')
    btn_idev.color = '#173349'
    input_text.set_text(f"IN: {dev['name']}")

update_input_device_ui()

def on_mic(event):
    if mode == 'mic':
        switch_to_idle()
    else:
        switch_to_mic()

def on_open_file(event):
    def _pick():
        path = pick_file_osascript()
        if path:
            load_audio_file(path)
    threading.Thread(target=_pick, daemon=True).start()

def take_snapshot(event):
    freqs, spec = compute_spectrum(audio_buffer.copy())
    line_snap.set_data(freqs, spec)
    print(f"[Snapshot] {datetime.now().strftime('%H:%M:%S')}")
    fig.canvas.draw_idle()

def flatten_eq(event):
    for sl in sliders:
        sl.set_val(0)

def stop_file(event):
    global mode, spectrum_smooth, analysis_smooth
    if mode == 'file' or play_stream is not None:
        stop_play_stream()
        mode = 'idle'
        audio_buffer.fill(0.0)
        analysis_buffer.fill(0.0)
        spectrum_smooth = None
        analysis_smooth = None
        update_source_buttons()
        fig.canvas.draw_idle()
        print("[File] playback stopped")
        return

    if start_file_playback(reset_position=True):
        if last_file_name:
            file_label.set_text(last_file_name[:50])
        update_source_buttons()
        fig.canvas.draw_idle()
        print("[File] playback started")

def toggle_eq(event):
    global eq_enabled
    eq_enabled = not eq_enabled
    reset_eq_zi()
    update_eq_toggle_button()
    refresh_eq_curve()
    fig.canvas.draw_idle()
    print(f"[EQ] {'enabled' if eq_enabled else 'disabled'}")

def toggle_auto_eq(event):
    global auto_eq_enabled, last_auto_eq_time, auto_eq_err_smooth, auto_eq_ref_rel
    auto_eq_enabled = not auto_eq_enabled
    last_auto_eq_time = 0.0
    auto_eq_err_smooth = np.zeros(len(EQ_FREQS), dtype=float)
    auto_eq_ref_rel = None
    update_auto_eq_button()
    fig.canvas.draw_idle()
    print(f"[AutoEQ] {'enabled' if auto_eq_enabled else 'disabled'}")

def toggle_original_hold(event):
    global original_hold_enabled, original_hold_spec, original_hold_freqs
    original_hold_enabled = not original_hold_enabled
    if original_hold_enabled:
        if analysis_smooth is not None:
            original_hold_spec = analysis_smooth.copy()
            freqs_now, _ = compute_spectrum(analysis_buffer.copy())
            original_hold_freqs = freqs_now
    else:
        original_hold_spec = None
        original_hold_freqs = None
    update_original_hold_button()
    fig.canvas.draw_idle()
    print(f"[Original] {'hold' if original_hold_enabled else 'live'}")

def cycle_input_device(event):
    global selected_input_idx
    if not input_devices:
        print("[Input] Нет доступных входных устройств")
        return
    selected_input_idx = (selected_input_idx + 1) % len(input_devices)
    was_mic = (mode == 'mic')
    if was_mic:
        try:
            stop_mic_stream()
            start_mic_stream()
        except Exception as e:
            print(f"[Input] Не удалось переключить микрофон: {e}")
    update_input_device_ui()
    fig.canvas.draw_idle()
    dev = input_devices[selected_input_idx]
    print(f"[Input] {dev['id']}: {dev['name']}")

def auto_adjust_eq(freqs, spec_db):
    """Подстроить полосы EQ к целевой форме спектра."""
    global auto_eq_err_smooth, auto_eq_ref_rel
    # На очень тихом сигнале решения нестабильны — пропускаем.
    if float(np.median(spec_db)) < AUTO_EQ_MIN_MEDIAN_DB:
        return

    levels = []
    band_factor = 2 ** (1 / 6)  # ~1/3 октавы
    for f0 in EQ_FREQS:
        low = f0 / band_factor
        high = f0 * band_factor
        m = (freqs >= low) & (freqs <= high)
        if np.any(m):
            levels.append(float(np.mean(spec_db[m])))
        else:
            levels.append(float(np.mean(spec_db)))
    levels = np.array(levels, dtype=float)
    rel = levels - np.median(levels)
    # Адаптация под конкретный инструмент: медленно учим его "естественный" тональный профиль.
    if auto_eq_ref_rel is None:
        auto_eq_ref_rel = rel.copy()
    else:
        auto_eq_ref_rel = (1.0 - AUTO_EQ_REF_ALPHA) * auto_eq_ref_rel + AUTO_EQ_REF_ALPHA * rel
    adaptive_target = 0.65 * AUTO_EQ_TARGET_REL_DB + 0.35 * auto_eq_ref_rel
    err = rel - adaptive_target
    auto_eq_err_smooth = 0.7 * auto_eq_err_smooth + 0.3 * err
    delta = -AUTO_EQ_STRENGTH * auto_eq_err_smooth
    # Слабая утечка к нейтрали для предотвращения накопительного дрейфа.
    delta -= AUTO_EQ_DAMPING * np.array(eq_gains, dtype=float)
    # Меньше агрессии на верхних полосах.
    delta *= AUTO_EQ_BAND_RESPONSE
    # Защита от излишней резкости: если верха заметно доминируют, прижимаем high-band boost.
    high_rel = np.mean(rel[5:7])
    mid_rel = np.mean(rel[3:5])
    high_excess = high_rel - mid_rel
    if high_excess > AUTO_EQ_HIGH_PENALTY_THRESHOLD_DB:
        penalty = AUTO_EQ_HIGH_PENALTY_STRENGTH * (high_excess - AUTO_EQ_HIGH_PENALTY_THRESHOLD_DB)
        delta[5] -= penalty
        delta[6] -= penalty
    delta = np.clip(delta, -AUTO_EQ_MAX_STEP_DB, AUTO_EQ_MAX_STEP_DB)

    new_gains = np.array(eq_gains, dtype=float) + delta
    new_gains = np.clip(new_gains, AUTO_EQ_BAND_MIN_DB, AUTO_EQ_BAND_MAX_DB)
    new_gains = np.clip(new_gains, -AUTO_EQ_ABS_LIMIT_DB, AUTO_EQ_ABS_LIMIT_DB)
    new_gains = np.clip(new_gains, -EQ_RANGE, EQ_RANGE)
    if np.max(np.abs(new_gains - np.array(eq_gains, dtype=float))) < AUTO_EQ_MIN_CHANGE_DB:
        return
    for sl, v in zip(sliders, new_gains):
        sl.set_val(float(np.round(v, 2)))

def save_eq(event):
    eq_data = {f'{f}Hz': round(g, 1) for f, g in zip(EQ_FREQS, eq_gains)}
    with open(EQ_SAVE_PATH, 'w', encoding='utf-8') as fp:
        json.dump(eq_data, fp, indent=2)
    print(f"[EQ saved] {EQ_SAVE_PATH}: {eq_data}")

btn_mic.on_clicked(on_mic)
btn_file.on_clicked(on_open_file)
btn_fstp.on_clicked(stop_file)
btn_snap.on_clicked(take_snapshot)
btn_aeqt.on_clicked(toggle_auto_eq)
btn_eqtg.on_clicked(toggle_eq)
btn_flat.on_clicked(flatten_eq)
btn_esav.on_clicked(save_eq)
btn_olck.on_clicked(toggle_original_hold)
btn_idev.on_clicked(cycle_input_device)

# ─── Анимация ────────────────────────────────────────────────
from scipy.ndimage import uniform_filter1d

def update(frame):
    global spectrum_smooth, analysis_smooth, hotspans, last_auto_eq_time
    global original_hold_spec, original_hold_freqs
    while ui_events:
        event, payload = ui_events.pop(0)
        if event == 'file_loaded':
            file_label.set_text(payload)
            update_source_buttons()
            fig.canvas.draw_idle()
        elif event == 'file_error':
            file_label.set_text('Load error')
            fig.canvas.draw_idle()

    if mode == 'idle':
        audio_buffer.fill(0.0)
        analysis_buffer.fill(0.0)

    freqs, spec = compute_spectrum(audio_buffer.copy())
    src_freqs, src_spec = compute_spectrum(analysis_buffer.copy())

    if spectrum_smooth is None or len(spectrum_smooth) != len(spec):
        spectrum_smooth = spec.copy()
    else:
        spectrum_smooth = SMOOTHING * spectrum_smooth + (1 - SMOOTHING) * spec

    if analysis_smooth is None or len(analysis_smooth) != len(src_spec):
        analysis_smooth = src_spec.copy()
    else:
        analysis_smooth = SMOOTHING * analysis_smooth + (1 - SMOOTHING) * src_spec

    if auto_eq_enabled and eq_enabled and mode in ('file', 'mic'):
        now = time.monotonic()
        if now - last_auto_eq_time >= AUTO_EQ_UPDATE_SEC:
            # Важно: AutoEQ слушает только исходный сигнал ДО EQ.
            auto_adjust_eq(src_freqs, analysis_smooth)
            last_auto_eq_time = now

    line_live.set_data(freqs, spectrum_smooth)
    if original_hold_enabled and original_hold_spec is not None and original_hold_freqs is not None:
        src_freqs_vis = original_hold_freqs
        src_base = original_hold_spec
    else:
        src_freqs_vis = src_freqs
        src_base = analysis_smooth
    src_vis = src_base + (OUTPUT_GAIN_DB if mode == 'file' else 0.0)
    line_src.set_data(src_freqs_vis, src_vis)

    # Пик
    idx = np.argmax(spectrum_smooth)
    peak_text.set_text(f'Peak: {freqs[idx]:.0f} Hz  {spectrum_smooth[idx]:.1f} dB')

    # Обновить кривую EQ на фиксированной базовой линии
    refresh_eq_curve()

    # Клиппинг
    max_a = np.max(np.abs(audio_buffer))
    if max_a > 0.95:
        clip_text.set_text(f'CLIP! max={max_a:.3f}')
        clip_text.set_color('#ff2200')
        clip_text.get_bbox_patch().set_edgecolor('#ff2200')
    else:
        clip_text.set_text(f'max={max_a:.3f}')
        clip_text.set_color('#00aa44')
        clip_text.get_bbox_patch().set_edgecolor('#00aa44')

    write_live_log(freqs[idx], spectrum_smooth[idx], max_a)

    # Красные зоны: локальные выбросы с абсолютным порогом.
    # Так зоны исчезают при реальном уменьшении уровня EQ/сигнала.
    for sp in hotspans:
        sp.remove()
    hotspans.clear()
    if len(spectrum_smooth) > 50:
        sm40  = uniform_filter1d(spectrum_smooth, size=40)
        bg200 = uniform_filter1d(sm40, size=200)
        diff  = sm40 - bg200
        hot   = (diff > HOT_DIFF_DB) & (sm40 > HOT_ABS_LEVEL_DB)
        tr    = np.diff(hot.astype(int))
        starts = list(np.where(tr == 1)[0] + 1)
        ends   = list(np.where(tr == -1)[0] + 1)
        if hot[0]: starts.insert(0, 0)
        if hot[-1]: ends.append(len(hot))
        for s, e in zip(starts, ends):
            sp = ax.axvspan(freqs[s], freqs[e-1], color='#ff2200', alpha=0.20, zorder=1)
            hotspans.append(sp)

    return line_live, line_src, line_eq, peak_text, clip_text

# ─── Запуск ──────────────────────────────────────────────────
print("=" * 55)
print("  Guitar EQ Analyzer")
print("  [MIC]        — микрофон (выключен по умолчанию)")
print("  [Open File]  — WAV / MP3 / M4A / FLAC")
print("  EQ слайдеры  — 7 полос ±12 dB")
print("  [Reset]      — сбросить EQ в ноль")
print("  [Snapshot]   — зафиксировать спектр")
print("  [Save EQ]    — сохранить EQ пресет в JSON")
print(f"  Output gain  — {OUTPUT_GAIN_DB:+.1f} dB headroom")
print("  Или: python3 guitar_eq.py /path/to/file")
print("=" * 55)

if len(sys.argv) > 1:
    fpath = ' '.join(sys.argv[1:])
    threading.Thread(target=load_audio_file, args=(fpath,), daemon=True).start()

ani = animation.FuncAnimation(fig, update, interval=60, blit=False, cache_frame_data=False)
plt.show()

stop_play_stream()
stop_mic_stream()
