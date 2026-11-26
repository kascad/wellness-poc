"""Fit and calibrate a shared mobile detector on grouped, fixed-length AMI clips."""
import argparse
import csv
import json
import io
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.special import expit
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import GroupShuffleSplit
from sklearn.preprocessing import StandardScaler

from train_cough import BANK, HANN, RATE, WINDOW, SEED, coughvid_rows, features, read_audio


def clip_features(audio):
    return np.stack([features(audio[i:i + WINDOW]) for i in range(0, len(audio) - WINDOW + 1, RATE // 4)])


def ami(root):
    with (root / "ami.csv").open() as handle:
        records = list(csv.DictReader(handle))
    for file in sorted((root / "ami").glob("*.wav")):
        rows = [r for r in records if r["Meeting ID"] == file.stem and r["Microphone"] == "Headset mix"]
        if not rows:
            continue
        rate, pcm = wavfile.read(file, mmap=True)
        positives = [(float(r["Start"]), float(r["End"])) for r in rows if r["Cough"] == "1"]
        for r in rows:
            if r["Cough"] not in ("0", "1") or r["close call"] == "1":
                continue
            start, end = float(r["Start"]), float(r["End"])
            middle = (start + end) / 2
            left, right = middle - 1.5, middle + 1.5
            label = int(r["Cough"])
            if left < 0 or right * rate > len(pcm):
                continue
            if label == 0 and any(a < right and b > left for a, b in positives):
                continue
            wav = io.BytesIO()
            wavfile.write(wav, rate, pcm[round(left * rate):round(right * rate)])
            clip = read_audio(wav.getvalue())[:3 * RATE]
            clip = np.pad(clip, (0, 3 * RATE - len(clip)))
            intervals = [(a-left, b-left) for a,b in positives if a < right and b > left]
            windows = clip_features(clip)
            target = [int(label and any(i / 4 <= a + .06 and i / 4 + 1 >= b - .06
                                         for a, b in intervals)) for i in range(len(windows))]
            yield file.stem, r["File number"], label, windows, target


def run(root, output, report):
    rows = list(ami(root))
    groups = [r[0] for r in rows]
    labels = np.array([r[2] for r in rows])
    target = np.array([sum(labels), len(labels) - sum(labels)]) / 4

    def balance(indices):
        positives = sum(labels[indices])
        counts = np.array([positives, len(indices) - positives])
        return np.sum(((counts - target) / target) ** 2)

    splits = []
    for train_idx, rest in GroupShuffleSplit(n_splits=80, test_size=.48, random_state=SEED).split(rows, groups=groups):
        for cal, test in GroupShuffleSplit(n_splits=12, test_size=.5, random_state=SEED).split(rest, groups=np.array(groups)[rest]):
            splits.append((balance(rest[cal]) + balance(rest[test]), train_idx, rest[cal], rest[test]))
    _, train_idx, cal, test = min(splits, key=lambda split: split[0])
    training, calibration, holdout = ([rows[i] for i in part] for part in (train_idx, cal, test))
    x, y, sample_weights = [], [], []
    for _, _, label, windows, target in training:
        for vector, annotated in zip(windows, target):
            if not label or annotated:
                x.append(vector)
                y.append(annotated)
                sample_weights.append(1.0)
    for vector, _, _, _ in coughvid_rows(root, 144):
        x.append(vector)
        y.append(1)
        sample_weights.append(.5)

    x = np.stack(x).astype(np.float64)
    scaler = StandardScaler().fit(x)
    estimator = LogisticRegression(C=.07, class_weight="balanced", max_iter=700)
    estimator.fit(scaler.transform(x), y, sample_weight=sample_weights)
    weights = estimator.coef_[0] / scaler.scale_
    bias = float(estimator.intercept_[0] - weights @ scaler.mean_)

    def scores(part):
        return np.array([np.max(r[3] @ weights + bias) for r in part])

    validation = scores(calibration)
    negatives = np.sort(validation[[r[2] == 0 for r in calibration]])
    if not len(negatives):
        raise ValueError("No negative calibration clips")
    allowed = int(.08 * len(negatives))
    threshold = float(np.nextafter(negatives[-allowed - 1], np.inf)) + 1e-6

    def evaluate(part):
        labels = np.array([r[2] for r in part], dtype=bool)
        predicted = scores(part) >= threshold
        return dict(meetings=sorted({r[0] for r in part}), positives=int(labels.sum()),
                    negatives=int((~labels).sum()), detected=int((labels & predicted).sum()),
                    false_positives=int((~labels & predicted).sum()))

    def array(name, values):
        flat = np.asarray(values).ravel()
        lines = [", ".join(format(v, ".17g") for v in flat[i:i + 8]) for i in range(0, len(flat), 8)]
        return f"static const double {name}[{len(flat)}] = {{\n    " + ",\n    ".join(lines) + "\n};\n"

    def mel_bank_sparse():
        bounds = [(int(row.nonzero()[0][0]), int(row.nonzero()[0][-1])+1) for row in BANK]
        payload = np.concatenate([row[a:b] for row, (a,b) in zip(BANK, bounds)])
        return (array("mel_start", [a for a,b in bounds]) +
                array("mel_length", [b-a for a,b in bounds]) + array("mel_weights", payload))

    output.write_text("/* Generated by train_mobile_cough.py. */\n" + array("model_weights", weights) +
                      array("model_parameters", [bias, threshold]) + array("hann", HANN) + mel_bank_sparse())
    result = dict(train_meetings=sorted({r[0] for r in training}), training_windows=len(y),
                  threshold_logit=threshold, threshold_score=float(expit(threshold)),
                  calibration=evaluate(calibration), holdout=evaluate(holdout))
    report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("data", type=Path)
    parser.add_argument("header", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    run(args.data, args.header, args.report)
