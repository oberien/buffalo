#!/usr/bin/env python3

import flask
from flask import Flask, send_from_directory, request
import sched, subprocess

app = Flask(__name__)
process = None
evt = None
s = sched.scheduler();

def render_template(page, **kwargs):
    return flask.make_response(flask.render_template(page, **kwargs))

@app.route("/")
@app.route("/index.html")
def root():
    return render_template('index.html')

@app.route("/start", methods=["POST"])
def start():
    global process, evt
    if process is not None:
        cancelevt()
        res = "Server stop timeout reset"
    else:
        process = subprocess.Popen(["./wolnas"])
        res = "Server started"
    evt = s.enter(3 * 60 * 60, 0, abort)
    return res

@app.route("/stop", methods=["POST"])
def stop():
    global process, evt
    if evt is not None:
        cancelevt()
    if process is None:
        return flask.make_response("Server not running", 400)
    abort()
    return "Server stopped"

def abort():
    global process
    p = process
    process = None
    p.terminate()
    try:
        p.wait(5)
    except TimeoutExpired:
        p.kill()
    p.wait(5)

def cancelevt():
    global evt
    s.cancel(evt)
    evt = None

