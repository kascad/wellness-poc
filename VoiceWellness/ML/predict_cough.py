"""Run the trained acoustic model on an audio file and group positive windows."""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.special import expit

from train_cough import RATE, WINDOW, features, read_audio


def detect(samples, model, hop=RATE // 4):
    weights = np.asarray(model["weights"])
    intervals = []
    if len(samples) < WINDOW:
        return intervals
    starts = list(range(0, len(samples) - WINDOW + 1, hop))
    if starts[-1] != len(samples) - WINDOW:
        starts.append(len(samples) - WINDOW)
    for start in starts:
        frame = samples[start:start + WINDOW]
        if np.max(np.abs(frame)) < 1e-4:
            continue
        score = float(expit(np.sum(features(frame) * weights) + model["intercept"]))
        if score < model["threshold"]:
            continue
        end = (start + WINDOW) / RATE
        start /= RATE
        if intervals and start <= intervals[-1]["end_seconds"]:
            intervals[-1]["end_seconds"] = end
            intervals[-1]["score"] = max(score, intervals[-1]["score"])
        else:
            intervals.append(dict(start_seconds=start, end_seconds=end, score=score))
    return intervals


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--model", type=Path, default=Path(__file__).with_name("results") / "cough-model.json")
    parser.add_argument("--start", type=float, default=0)
    parser.add_argument("--duration", type=float)
    args = parser.parse_args()
    if args.start < 0 or (args.duration is not None and args.duration <= 0):
        parser.error("start must be nonnegative and duration must be positive")
    model = json.loads(args.model.read_text())
    audio = read_audio(args.audio.read_bytes())
    end = None if args.duration is None else int((args.start + args.duration) * RATE)
    samples = audio[int(args.start * RATE):end]
    result = detect(samples, model)
    for interval in result:
        interval["start_seconds"] += args.start
        interval["end_seconds"] += args.start
    print(json.dumps(dict(episodes=len(result), analyzed_seconds=len(samples) / RATE, intervals=result), indent=2))


if __name__ == "__main__":
    main()
