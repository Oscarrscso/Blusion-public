'use strict';
// Subtitle fixtures with KNOWN cue times. Tests assert against CUES.
// start/end are seconds.
const CUES = [
  { start: 1.0, end: 3.0, text: 'First cue' },
  { start: 4.5, end: 6.25, text: 'Second cue\nwith two lines' },
  { start: 8.0, end: 9.5, text: 'Third cue' },
];

function pad(n, w) { return String(n).padStart(w, '0'); }

function stamp(sec, sep) {
  const ms = Math.round(sec * 1000);
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  const r = ms % 1000;
  return `${pad(h, 2)}:${pad(m, 2)}:${pad(s, 2)}${sep}${pad(r, 3)}`;
}

const SRT = CUES.map((c, i) => `${i + 1}\n${stamp(c.start, ',')} --> ${stamp(c.end, ',')}\n${c.text}\n`).join('\n');
const VTT = 'WEBVTT\n\n' + CUES.map((c, i) => `cue-${i + 1}\n${stamp(c.start, '.')} --> ${stamp(c.end, '.')}\n${c.text}\n`).join('\n');

module.exports = { CUES, SRT, VTT };
