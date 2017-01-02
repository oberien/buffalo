#!/usr/bin/env python3

import flask
from flask import Flask, send_from_directory, request
import os, threading, subprocess

pwd = os.environ.get("PASSWORD")
app = Flask(__name__)
process = None
timer = None

def render_template(page, **kwargs):
    return flask.make_response(flask.render_template(page, **kwargs))

@app.route("/")
@app.route("/index.html")
def root():
    return render_template('index.html')

@app.route("/start", methods=["POST"])
def start():
    password = request.form.get("password");
    if pwd is not None and password != pwd:
        return flask.make_response("Wrong password", 401)
    global process, timer
    if process is not None:
        canceltimer()
        res = "Server stop timeout reset"
    else:
        process = subprocess.Popen(["./wolnas"])
        res = "Server started"
    timer = threading.Timer(3 * 60 * 60, abort)
    timer.start()
    return res

@app.route("/stop", methods=["POST"])
def stop():
    password = request.form.get("password");
    if pwd is not None and password != pwd:
        return flask.make_response("Wrong password", 401)
    global process, timer
    if timer is not None:
        canceltimer()
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

def canceltimer():
    global timer
    timer.cancel()
    timer = None

