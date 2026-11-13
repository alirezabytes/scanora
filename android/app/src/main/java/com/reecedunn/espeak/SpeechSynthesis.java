package com.reecedunn.espeak;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Build;
import android.os.SystemClock;
import androidx.annotation.Keep;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

@Keep
public class SpeechSynthesis {
    static {
        try {
            System.loadLibrary("ttsespeak");
            nativeClassInit();
        } catch (Throwable t) {
            t.printStackTrace();
        }
    }

    private int mSampleRate = 22050;
    private boolean mInitialized = false;
    private String mCurrentDataPath = null;
    private AudioTrack mAudioTrack = null;
    private ByteArrayOutputStream mCaptureBuffer = null;
    private volatile boolean mCapturingToBuffer = false;

    public synchronized boolean ensureInitialized(String dataParentPath) {
        if (mInitialized && dataParentPath != null && dataParentPath.equals(mCurrentDataPath)) {
            return true;
        }
        try {
            int rate = nativeCreate(dataParentPath);
            if (rate > 0) {
                mSampleRate = rate;
                mInitialized = true;
                mCurrentDataPath = dataParentPath;
                return true;
            }
        } catch (Throwable t) {
            t.printStackTrace();
        }
        return false;
    }

    public int getSampleRate() {
        return mSampleRate > 0 ? mSampleRate : 22050;
    }

    public synchronized void configureVoice(
            String voiceName,
            int rate,
            int volume,
            int pitch,
            int pitchRange,
            int wordGap,
            int punctuation,
            int capitalsMode,
            String customPunctChars
    ) {
        if (!mInitialized) return;
        try {
            if (voiceName != null && !voiceName.isEmpty()) {
                boolean ok = nativeSetVoiceByName(voiceName);
                if (!ok && voiceName.contains("+")) {
                    String baseVoice = voiceName.substring(0, voiceName.indexOf('+'));
                    nativeSetVoiceByName(baseVoice);
                }
            }
            nativeSetParameter(1, Math.max(80, Math.min(1350, rate)));
            nativeSetParameter(2, Math.max(0, Math.min(200, volume)));
            nativeSetParameter(3, Math.max(0, Math.min(100, pitch)));
            nativeSetParameter(4, Math.max(0, Math.min(100, pitchRange)));
            nativeSetParameter(5, Math.max(0, Math.min(2, punctuation)));
            nativeSetParameter(6, Math.max(0, capitalsMode));
            nativeSetParameter(7, Math.max(0, Math.min(50, wordGap)));
            if (punctuation == 2 && customPunctChars != null && !customPunctChars.isEmpty()) {
                nativeSetPunctuationCharacters(customPunctChars);
            }
        } catch (Throwable t) {
            t.printStackTrace();
        }
    }

    private int mTrackSampleRate = 0;
    private volatile boolean mStopRequested = false;
    private long mFramesWritten = 0;

    public synchronized void speakLive(String text) {
        speakLive(text, false);
    }

    public synchronized void speakLive(String text, boolean ssml) {
        if (!mInitialized || text == null || text.trim().isEmpty()) return;
        mStopRequested = false;
        byte[] pcm = synthesizeToPcm(text, ssml);
        if (mStopRequested) return;
        if (pcm.length == 0) throw new IllegalStateException("No speech audio was produced");
        int sampleRate = getSampleRate();
        int frames = pcm.length / 2;
        AudioTrack track = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setBufferSizeInBytes(Math.max(4, pcm.length))
                .setTransferMode(AudioTrack.MODE_STATIC).build();
        mAudioTrack = track;
        try {
            // Static writes start at the beginning of the buffer. Require the
            // complete clip in one write so short boosted utterances also play.
            int count = track.write(pcm, 0, pcm.length, AudioTrack.WRITE_BLOCKING);
            if (count != pcm.length && !mStopRequested)
                throw new IllegalStateException("Audio output rejected speech");
            if (mStopRequested) return;
            track.play();
            long deadline = SystemClock.elapsedRealtime() + frames * 1000L / sampleRate + 3000L;
            while (!mStopRequested && mAudioTrack == track &&
                    SystemClock.elapsedRealtime() < deadline) {
                long played = track.getPlaybackHeadPosition() & 0xFFFFFFFFL;
                if (played >= frames) break;
                try { Thread.sleep(8); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); break; }
            }
        } finally {
            if (mAudioTrack == track) stopAudioTrack();
        }
    }

    public synchronized byte[] synthesizeToPcm(String text) {
        return synthesizeToPcm(text, false);
    }

    public synchronized byte[] synthesizeToPcm(String text, boolean ssml) {
        if (!mInitialized || text == null || text.trim().isEmpty()) return new byte[0];
        stopAudioTrack();
        mCaptureBuffer = new ByteArrayOutputStream();
        mCapturingToBuffer = true;
        try {
            nativeSynthesize(text, ssml);
            return mCaptureBuffer.toByteArray();
        } catch (Throwable t) {
            t.printStackTrace();
            return new byte[0];
        } finally {
            mCapturingToBuffer = false;
        }
    }

    public synchronized byte[] synthesizeToWav(String text) {
        return synthesizeToWav(text, false);
    }

    public synchronized byte[] synthesizeToWav(String text, boolean ssml) {
        byte[] pcm = synthesizeToPcm(text, ssml);
        return pcmToWav(pcm, getSampleRate());
    }

    public static byte[] pcmToWav(byte[] pcmData, int sampleRate) {
        int totalDataLen = pcmData.length + 36;
        int byteRate = sampleRate * 2; // 1 channel * 16-bit (2 bytes)
        ByteBuffer header = ByteBuffer.allocate(44);
        header.order(ByteOrder.LITTLE_ENDIAN);
        header.put(new byte[]{'R', 'I', 'F', 'F'});
        header.putInt(totalDataLen);
        header.put(new byte[]{'W', 'A', 'V', 'E'});
        header.put(new byte[]{'f', 'm', 't', ' '});
        header.putInt(16); // Subchunk1Size for PCM
        header.putShort((short) 1); // AudioFormat 1 = PCM
        header.putShort((short) 1); // NumChannels 1 = Mono
        header.putInt(sampleRate);
        header.putInt(byteRate);
        header.putShort((short) 2); // BlockAlign
        header.putShort((short) 16); // BitsPerSample
        header.put(new byte[]{'d', 'a', 't', 'a'});
        header.putInt(pcmData.length);

        byte[] wav = new byte[44 + pcmData.length];
        System.arraycopy(header.array(), 0, wav, 0, 44);
        System.arraycopy(pcmData, 0, wav, 44, pcmData.length);
        return wav;
    }

    public void stop() {
        mStopRequested = true;
        try {
            nativeStop();
        } catch (Throwable ignored) {
        }
        stopAudioTrack();
    }

    private void stopAudioTrack() {
        AudioTrack track = mAudioTrack;
        mAudioTrack = null;
        if (track != null) {
            try {
                if (track.getPlayState() == AudioTrack.PLAYSTATE_PLAYING) {
                    track.pause();
                    track.flush();
                    track.stop();
                }
                track.release();
            } catch (Throwable ignored) {
            }
        }
    }

    @Keep
    private void nativeSynthCallback(byte[] audioData) {
        if (audioData == null || audioData.length == 0) {
            return;
        }
        if (mCapturingToBuffer && mCaptureBuffer != null) {
            try {
                mCaptureBuffer.write(audioData);
            } catch (Throwable ignored) {
            }
        } else {
            AudioTrack track = mAudioTrack;
            if (track != null) {
                try {
                    int written = track.write(audioData, 0, audioData.length);
                    if (written > 0) mFramesWritten += written / 2;
                } catch (Throwable ignored) {
                }
            }
        }
    }

    @Keep
    private void nativeSynthWordCallback(int textPosition, int textLength, int markerInFrames) {
        // Optional word boundary callback from eSpeak-NG
    }

    @Keep
    private static native final boolean nativeClassInit();

    @Keep
    private native final int nativeCreate(String path);

    @Keep
    private native final static String nativeGetVersion();

    @Keep
    public native final String[] nativeGetAvailableVoices();

    @Keep
    private native final boolean nativeSetVoiceByName(String name);

    @Keep
    private native final boolean nativeSetVoiceByProperties(String language, int gender, int age);

    @Keep
    private native final boolean nativeSetParameter(int parameter, int value);

    @Keep
    private native final int nativeGetParameter(int parameter, int current);

    @Keep
    private native final boolean nativeSetPunctuationCharacters(String characters);

    @Keep
    private native final boolean nativeSynthesize(String text, boolean isSsml);

    @Keep
    private native final boolean nativeStop();
}
