#!/usr/bin/env python3
"""
Guitar Spectrum Analyzer
— MIC: реалтайм с микрофона
— FILE: аудиофайл (WAV/FLAC/AIFF/MP3/M4A через ffmpeg), с воспроизведением
"""

import numpy as np
import sounddevice as sd
import soundfile as sf
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from matplotlib.widgets import Button
from datetime import datetime
import subprocess, tempfile, os, threading, sys, atexit, fcntl

# ─── Параметры ───────────────────────────────────────────────
SAMPLE_RATE = 44100
BLOCK_SIZE  = 4096
FREQ_MIN    = 50
FREQ_MAX    = 8000
SMOOTHING   = 0.7
FIG_WIDTH_PX = 1100
FIG_HEIGHT_PX = 620

_instance_lock = None

def acquire_single_instance_lock():
    """Запретить запуск второй копии программы."""
    global _instance_lock
    lock_path = "/tmp/guitar_spectrum_analyzer.lock"
    _instance_lock = open(lock_path, "w")
    try:
        fcntl.flock(_instance_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("[Error] Guitar Spectrum Analyzer уже запущен. Закрой первую копию.")
        sys.exit(1)
    _instance_lock.write(str(os.getpid()))
    _instance_lock.flush()
    atexit.register(_instance_lock.close)

acquire_single_instance_lock()

# ─── Состояние ───────────────────────────────────────────────
audio_buffer    = np.zeros(BLOCK_SIZE)
spectrum_smooth = None
mode            = 'mic'   # 'mic' | 'file' | 'idle'
file_position   = 0
file_data       = None
play_stream     = None
ui_events       = []

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
    stream = getattr(start_mic_stream, "_stream", None)
    if stream is not None:
        return
    stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        blocksize=int(BLOCK_SIZE * 0.25),
        channels=1,
        callback=audio_callback,
        dtype='float32'
    )
    stream.start()
    start_mic_stream._stream = stream

def stop_mic_stream():
    """Полностью остановить и закрыть поток микрофона."""
    stream = getattr(start_mic_stream, "_stream", None)
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
    start_mic_stream._stream = None

# ─── Аудио коллбэки ──────────────────────────────────────────
def audio_callback(indata, frames, time, status):
    """Коллбэк микрофона — пишет в буфер только в режиме MIC."""
    global audio_buffer
    if mode != 'mic':
        return
    mono = indata[:, 0] if indata.ndim > 1 else indata.flatten()
    audio_buffer = np.roll(audio_buffer, -len(mono))
    audio_buffer[-len(mono):] = mono

def file_callback(outdata, frames, time, status):
    """Коллбэк воспроизведения файла — пишет в буфер и на выход."""
    global audio_buffer, file_position
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

    outdata[:, 0]  = chunk
    audio_buffer   = np.roll(audio_buffer, -frames)
    audio_buffer[-frames:] = chunk

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
    global file_data, file_position, mode, play_stream
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

        stop_play_stream()

        file_data     = data
        file_position = 0
        mode          = 'file'
        stop_mic_stream()

        play_stream = sd.OutputStream(
            samplerate=SAMPLE_RATE, blocksize=512,
            channels=1, callback=file_callback, dtype='float32'
        )
        play_stream.start()

        name = os.path.basename(path)
        ui_events.append(('file_loaded', name))
        print(f"[File] {name}  |  {len(data)/SAMPLE_RATE:.1f} sec")

    except Exception as e:
        ui_events.append(('file_error', str(e)))
        print(f"[Error] {e}")

def switch_to_mic():
    global mode
    stop_play_stream()
    mode = 'mic'
    start_mic_stream()
    file_text.set_text('')
    update_source_buttons()
    fig.canvas.draw_idle()
    print("[MIC] switched to microphone")

def switch_to_idle():
    """Полностью выключить микрофон и воспроизведение файла."""
    global mode, spectrum_smooth
    stop_play_stream()
    stop_mic_stream()
    mode = 'idle'
    audio_buffer.fill(0.0)
    spectrum_smooth = None
    update_source_buttons()
    fig.canvas.draw_idle()
    print("[MIC] disabled")

def pick_file_osascript():
    script = (
        'POSIX path of (choose file with prompt "Выбери аудиофайл" '
        'of type {"public.audio", "com.microsoft.waveform-audio", '
        '"public.mp3", "public.aiff-audio"})'
    )
    result = subprocess.run(['osascript', '-e', script],
                            capture_output=True, text=True)
    path = result.stdout.strip()
    return path if path else None

# ─── FFT ─────────────────────────────────────────────────────
def compute_spectrum(buffer):
    window  = np.hanning(len(buffer))
    fft     = np.abs(np.fft.rfft(buffer * window)) / len(buffer)
    fft_db  = 20 * np.log10(fft + 1e-10)
    freqs   = np.fft.rfftfreq(len(buffer), 1 / SAMPLE_RATE)
    mask    = (freqs >= FREQ_MIN) & (freqs <= FREQ_MAX)
    return freqs[mask], fft_db[mask]

# ─── GUI ─────────────────────────────────────────────────────
fig_dpi = float(plt.rcParams.get("figure.dpi", 100))
fig, ax = plt.subplots(figsize=(FIG_WIDTH_PX / fig_dpi, FIG_HEIGHT_PX / fig_dpi), dpi=fig_dpi)
fig.patch.set_facecolor('#0e0e0e')
ax.set_facecolor('#0e0e0e')
plt.subplots_adjust(bottom=0.18)

freqs_init, spec_init = compute_spectrum(audio_buffer)
line_live, = ax.plot(freqs_init, spec_init, color='#00ff88', lw=1.2, label='Live')
line_snap, = ax.plot([], [], color='#ff6644', lw=1.5, ls='--', alpha=0.85, label='Snapshot')

ax.set_xlim(FREQ_MIN, FREQ_MAX)
ax.set_ylim(-100, 0)
ax.set_xscale('log')
ax.set_xlabel('Frequency, Hz', color='#aaaaaa')
ax.set_ylabel('Amplitude, dB', color='#aaaaaa')
ax.set_title('Guitar Spectrum Analyzer', color='white', fontsize=14)
ax.tick_params(colors='#888888')
ax.grid(True, which='both', color='#2a2a2a', linewidth=0.5)
ax.legend(loc='upper right', facecolor='#1a1a1a', labelcolor='white', edgecolor='#444444')

peak_text = ax.text(0.02, 0.96, '', transform=ax.transAxes,
                    color='#00ff88', fontsize=10, va='top',
                    bbox=dict(boxstyle='round', fc='#111111', ec='#00ff88', alpha=0.8))
file_text = ax.text(0.50, 0.96, '', transform=ax.transAxes,
                    color='#aaaaaa', fontsize=9, va='top', ha='center')

# Кнопки: [MIC] [Open File...] | [Snapshot] [Save PNG]
ax_btn_mic  = plt.axes([0.08, 0.04, 0.12, 0.08])
ax_btn_file = plt.axes([0.22, 0.04, 0.18, 0.08])
ax_btn_snap = plt.axes([0.50, 0.04, 0.18, 0.08])
ax_btn_save = plt.axes([0.70, 0.04, 0.18, 0.08])

btn_mic  = Button(ax_btn_mic,  'MIC',         color='#1a3a1a', hovercolor='#2a5a2a')
btn_file = Button(ax_btn_file, 'Open File...', color='#1a1a3a', hovercolor='#2a2a5a')
btn_snap = Button(ax_btn_snap, 'Snapshot',     color='#3a2a00', hovercolor='#5a4400')
btn_save = Button(ax_btn_save, 'Save PNG',     color='#3a1a1a', hovercolor='#5a2a2a')
for b in (btn_mic, btn_file, btn_snap, btn_save):
    b.label.set_color('white')

def update_source_buttons():
    if mode == 'mic':
        btn_mic.color  = '#00aa44'
        btn_mic.label.set_text('MIC ON')
        btn_file.color = '#1a1a3a'
    elif mode == 'file':
        btn_mic.color  = '#1a3a1a'
        btn_mic.label.set_text('MIC OFF')
        btn_file.color = '#0044aa'
    else:
        btn_mic.color  = '#555555'
        btn_mic.label.set_text('MIC OFF')
        btn_file.color = '#1a1a3a'
    btn_mic.ax.set_facecolor(btn_mic.color)
    btn_file.ax.set_facecolor(btn_file.color)

update_source_buttons()

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

def save_png(event):
    fname = f"spectrum_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
    fig.savefig(fname, facecolor=fig.get_facecolor(), dpi=150)
    print(f"[Saved] {fname}")

btn_mic.on_clicked(on_mic)
btn_file.on_clicked(on_open_file)
btn_snap.on_clicked(take_snapshot)
btn_save.on_clicked(save_png)

# ─── Анимация ────────────────────────────────────────────────
def update(frame):
    global spectrum_smooth
    while ui_events:
        event, payload = ui_events.pop(0)
        if event == 'file_loaded':
            file_text.set_text(payload)
            update_source_buttons()
            fig.canvas.draw_idle()
        elif event == 'file_error':
            file_text.set_text('Load error')
            fig.canvas.draw_idle()

    if mode == 'idle':
        audio_buffer.fill(0.0)

    freqs, spec = compute_spectrum(audio_buffer.copy())

    if spectrum_smooth is None or len(spectrum_smooth) != len(spec):
        spectrum_smooth = spec.copy()
    else:
        spectrum_smooth = SMOOTHING * spectrum_smooth + (1 - SMOOTHING) * spec

    line_live.set_data(freqs, spectrum_smooth)

    idx = np.argmax(spectrum_smooth)
    peak_text.set_text(f'Peak: {freqs[idx]:.1f} Hz  /  {spectrum_smooth[idx]:.1f} dB')

    return line_live, peak_text

# ─── Запуск ──────────────────────────────────────────────────
print("=" * 50)
print("  Guitar Spectrum Analyzer")
print("  [MIC]       — микрофон (активен по умолчанию)")
print("  [Open File] — нативный диалог выбора файла")
print("  [Snapshot]  — зафиксировать спектр")
print("  [Save PNG]  — сохранить график")
print("  Или: python3 guitar_spectrum.py /path/to/file")
print("=" * 50)

if len(sys.argv) > 1:
    fpath = ' '.join(sys.argv[1:])
    threading.Thread(target=load_audio_file, args=(fpath,), daemon=True).start()

start_mic_stream()
ani = animation.FuncAnimation(fig, update, interval=50, blit=True, cache_frame_data=False)
plt.show()

stop_play_stream()
stop_mic_stream()
