"""Train a small acoustic cough classifier and export a Core ML feature head."""
import argparse
import collections
import csv
import io
import json
from pathlib import Path
import random
import subprocess
import zipfile

import numpy as np
from scipy import signal
from scipy.io import wavfile
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, confusion_matrix, precision_recall_curve, roc_auc_score
from sklearn.model_selection import GroupShuffleSplit
from sklearn.preprocessing import StandardScaler

RATE = 16000
WINDOW = RATE
FRAME = 400
HOP = 160
FFT = 512
SEED = 26


def mel_bank():
    mel = lambda hz: 2595 * np.log10(1 + hz / 700)
    edges = 700 * (10 ** (np.linspace(mel(70), mel(7600), 26) / 2595) - 1)
    frequencies = np.fft.rfftfreq(FFT, 1 / RATE)
    return np.stack([
        np.maximum(0, np.minimum((frequencies - left) / (middle - left),
                                 (right - frequencies) / (right - middle)))
        for left, middle, right in zip(edges, edges[1:], edges[2:])
    ])


BANK = mel_bank()
HANN = np.hanning(FRAME)


def features(samples):
    """A one-second, mono 16 kHz frame. Ordinal feature order is documented."""
    framed = np.lib.stride_tricks.sliding_window_view(samples, FRAME)[::HOP]
    energy = np.mean(framed ** 2, axis=1)
    pcm = samples / max(np.sqrt(np.max(energy)), 1e-6)
    frames = np.lib.stride_tricks.sliding_window_view(pcm, FRAME)[::HOP]
    power = np.abs(np.fft.rfft(frames * HANN, FFT)) ** 2 / FFT
    mel = np.log(np.maximum(np.einsum("tf,mf->tm", power, BANK), 1e-8))
    active = energy > max(1e-10, np.max(energy) / 1000)
    useful = mel[active] if active.any() else mel
    delta = np.diff(mel, axis=0)
    return np.concatenate([
        useful.mean(axis=0), useful.std(axis=0), np.percentile(useful, 90, axis=0),
        np.abs(delta).mean(axis=0),
        [active.mean(), np.argmax(energy) / len(energy),
         np.mean(np.diff(np.signbit(pcm))), np.max(np.abs(pcm)), np.log(max(energy.max(), 1e-10))]
    ]).astype(np.float32)


def read_audio(data):
    try:
        rate, values = wavfile.read(io.BytesIO(data))
        samples = values.astype(np.float32)
        if np.issubdtype(values.dtype, np.integer):
            samples /= max(abs(np.iinfo(values.dtype).min), 1)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        return signal.resample_poly(samples, RATE, rate).astype(np.float32) if rate != RATE else samples
    except (ValueError, EOFError):
        command = ["ffmpeg", "-v", "error", "-i", "pipe:0", "-ac", "1", "-ar", str(RATE), "-f", "f32le", "pipe:1"]
        result = subprocess.run(command, input=data, capture_output=True, check=True)
        return np.frombuffer(result.stdout, dtype="<f4")


def crop(samples, center=None):
    if len(samples) < WINDOW:
        left = (WINDOW - len(samples)) // 2
        return np.pad(samples, (left, WINDOW - len(samples) - left))
    if center is None:
        blocks = samples[:len(samples) // 320 * 320].reshape(-1, 320)
        center = int(np.argmax(np.mean(blocks ** 2, axis=1))) * 320 + 160
    start = np.clip(center - WINDOW // 2, 0, len(samples) - WINDOW)
    return samples[start:start + WINDOW]


def fsd_rows(root):
    with (root / "fsd_subset.csv").open() as handle:
        for row in csv.DictReader(handle):
            name = row["fname"]
            path = root / "fsd" / (name + ".wav")
            if not path.exists():
                continue
            label = int("Cough" in row["labels"].split(","))
            yield features(crop(read_audio(path.read_bytes()))), label, row["uploader"], name


def coughvid_rows(root, limit):
    selected = root / "coughvid_subset.csv"
    if selected.exists():
        with selected.open() as handle:
            for row in csv.DictReader(handle):
                path = root / "coughvid" / row["filename"]
                try:
                    values = read_audio(path.read_bytes())
                    if len(values) >= RATE // 4:
                        yield features(crop(values)), 1, row["filename"], row["filename"]
                except (OSError, subprocess.CalledProcessError):
                    continue
        return
    with zipfile.ZipFile(root / "coughvid.zip") as archive:
        metadata = next(name for name in archive.namelist() if name.endswith("metadata_compiled.csv"))
        rows = csv.DictReader(io.StringIO(archive.read(metadata).decode("utf-8-sig")))
        candidates = [row["uuid"] for row in rows
                      if float(row.get("cough_detected", "") or 0) >= 0.95]
        by_id = {Path(name).stem: name for name in archive.namelist()
                 if Path(name).suffix.lower() in {".webm", ".ogg", ".wav", ".mp4"}}
        random.Random(SEED).shuffle(candidates)
        for name in [name for name in candidates if name in by_id][:limit]:
            try:
                samples = read_audio(archive.read(by_id[name]))
                if len(samples) >= RATE // 4:
                    yield features(crop(samples)), 1, name, name
            except (ValueError, subprocess.CalledProcessError):
                continue


def ami_rows(root):
    with (root / "ami.csv").open() as handle:
        rows = list(csv.DictReader(handle))
    for file in sorted((root / "ami").glob("*.wav")):
        meeting = file.stem
        audio = read_audio(file.read_bytes())
        events = [r for r in rows if r["Meeting ID"] == meeting and r["Microphone"].lower() == "headset mix"]
        positives = [(float(r["Start"]), float(r["End"])) for r in events if r["Cough"] == "1"]
        for row in events:
            if row["Cough"] not in ("0", "1"):
                continue
            start, end = float(row["Start"]), float(row["End"])
            midpoint = (start + end) / 2
            label = int(row["Cough"])
            if end * RATE > len(audio) or midpoint < 0.5:
                continue
            if not label and any(a < midpoint + 0.5 and b > midpoint - 0.5 for a, b in positives):
                continue
            yield features(crop(audio, int(midpoint * RATE))), label, meeting, row["File number"]


def evaluate(rows, predict, threshold):
    if not rows:
        return None
    x, y, _, _ = zip(*rows)
    scores = predict(np.stack(x))
    tn, fp, fn, tp = confusion_matrix(y, scores >= threshold, labels=[0, 1]).ravel()
    summary = dict(clips=len(y), true_positive=int(tp), false_positive=int(fp),
                   true_negative=int(tn), false_negative=int(fn))
    if len(set(y)) > 1:
        summary.update(roc_auc=float(roc_auc_score(y, scores)),
                       average_precision=float(average_precision_score(y, scores)))
    return summary


def select_threshold(rows, predict):
    x, y, _, _ = zip(*rows)
    precision, recall, thresholds = precision_recall_curve(y, predict(np.stack(x)))
    f1 = 2 * precision[:-1] * recall[:-1] / np.maximum(precision[:-1] + recall[:-1], 1e-10)
    return float(thresholds[np.argmax(f1)])


def fsd_split(rows):
    x, y, groups, _ = zip(*rows)
    for train, rest in GroupShuffleSplit(n_splits=40, test_size=0.4, random_state=SEED).split(x, y, groups):
        remainder = [rows[i] for i in rest]
        for validation, test in GroupShuffleSplit(n_splits=12, test_size=0.5, random_state=SEED).split(
                rest, groups=[row[2] for row in remainder]):
            parts = [[rows[i] for i in train], [remainder[i] for i in validation], [remainder[i] for i in test]]
            if all(min(collections.Counter(row[1] for row in part).get(label, 0) for label in (0, 1)) >= 5 for part in parts):
                return parts
    raise ValueError("FSD subset does not support uploader-separated splits with both classes")


def export_coreml(out, model, scaler, threshold):
    import coremltools as ct
    from coremltools.proto import Model_pb2

    spec = Model_pb2.Model()
    spec.specificationVersion = 1
    spec.description.metadata.shortDescription = "Prototype cough classifier on 101 acoustic features"
    spec.description.metadata.userDefined["cough_threshold"] = str(threshold)
    feature = spec.description.input.add()
    feature.name = "acoustic_features"
    feature.type.multiArrayType.shape.append(101)
    feature.type.multiArrayType.dataType = ct.proto.FeatureTypes_pb2.ArrayFeatureType.DOUBLE
    output = spec.description.output.add()
    output.name = "logit"
    output.type.doubleType.SetInParent()
    spec.description.predictedFeatureName = output.name
    head = spec.glmRegressor
    weights = model.coef_[0] / scaler.scale_
    head.offset.append(float(model.intercept_[0] - np.sum(weights * scaler.mean_)))
    head.weights.add().value.extend(weights.tolist())
    path = out / "CoughAcoustic.mlmodel"
    ct.models.utils.save_spec(spec, str(path))
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--coughvid-limit", type=int, default=250)
    args = parser.parse_args()
    root, out = args.data, args.output
    out.mkdir(parents=True, exist_ok=True)

    fsd = list(fsd_rows(root))
    coughvid = list(coughvid_rows(root, args.coughvid_limit))
    ami = list(ami_rows(root))
    if len(coughvid) < 30:
        raise ValueError("Not enough usable COUGHVID positives")
    train_fsd, validation, test = fsd_split(fsd)
    train_cv, test_cv = coughvid[:-max(10, len(coughvid)//5)], coughvid[-max(10, len(coughvid)//5):]
    train = train_fsd + train_cv
    x, y, _, _ = zip(*train)
    x = np.stack(x)
    if not np.isfinite(x).all():
        raise ValueError("Non-finite acoustic features")
    scaler = StandardScaler().fit(x)
    model = LogisticRegression(class_weight="balanced", max_iter=500, random_state=SEED)
    model.fit(scaler.transform(x), y)
    predict = lambda samples: model.predict_proba(scaler.transform(samples))[:, 1]
    threshold = select_threshold(validation, predict)

    weights = model.coef_[0] / scaler.scale_
    intercept = float(model.intercept_[0] - np.sum(weights * scaler.mean_))
    path = export_coreml(out, model, scaler, threshold)
    import coremltools as ct
    compiled = ct.models.MLModel(str(path))
    logits = compiled.predict({"acoustic_features": x[0].astype(np.float64)})["logit"]
    np.testing.assert_allclose(logits, model.decision_function(scaler.transform(x[:1]))[0], rtol=1e-5, atol=1e-5)
    report = dict(seed=SEED, threshold=threshold, train=dict(FSD50K=len(train_fsd), COUGHVID=len(train_cv)),
                  calibration_FSD50K=evaluate(validation, predict, threshold),
                  test_FSD50K=evaluate(test, predict, threshold),
                  test_COUGHVID_positive_only=evaluate(test_cv, predict, threshold),
                  test_AMI_annotated_windows=evaluate(ami, predict, threshold))
    (out / "cough-model.json").write_text(json.dumps(dict(weights=weights.tolist(), intercept=intercept, threshold=threshold), indent=2))
    (out / "evaluation.json").write_text(json.dumps(report, indent=2))
    manifest = [(split, source, identifier, group, label)
                for split, source, rows in [
                    ("train", "FSD50K", train_fsd), ("validation", "FSD50K", validation),
                    ("test", "FSD50K", test), ("train", "COUGHVID", train_cv),
                    ("test", "COUGHVID", test_cv), ("test", "AMI", ami)]
                for _, label, group, identifier in rows]
    with (out / "split-manifest.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["split", "source", "clip", "group", "label"])
        writer.writerows(manifest)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
