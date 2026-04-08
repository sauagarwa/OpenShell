# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""OpenShell Dashboard — lightweight web UI for managing sandboxes."""

import os
import time

import grpc
from flask import Flask, jsonify, render_template, request

import openshell_pb2 as pb
import openshell_pb2_grpc as pb_grpc
import datamodel_pb2 as dm

app = Flask(__name__)

GATEWAY = os.environ.get("OPENSHELL_GATEWAY", "openshell.openshell.svc.cluster.local:8080")

PHASE_NAMES = {
    0: "Unspecified",
    1: "Provisioning",
    2: "Ready",
    3: "Error",
    4: "Deleting",
    5: "Unknown",
}


def _channel():
    return grpc.insecure_channel(GATEWAY)


def _sandbox_to_dict(s):
    conditions = []
    if s.status:
        for c in s.status.conditions:
            conditions.append({
                "type": c.type,
                "status": c.status,
                "reason": c.reason,
                "message": c.message,
            })

    return {
        "id": s.id,
        "name": s.name,
        "namespace": s.namespace,
        "phase": PHASE_NAMES.get(s.phase, "Unknown"),
        "phase_id": s.phase,
        "created_at": s.created_at_ms,
        "pod": s.status.agent_pod if s.status else "",
        "conditions": conditions,
    }


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/health")
def health():
    try:
        with _channel() as ch:
            stub = pb_grpc.OpenShellStub(ch)
            resp = stub.Health(pb.HealthRequest(), timeout=5)
            return jsonify({"status": resp.status, "version": resp.version})
    except grpc.RpcError as e:
        return jsonify({"error": str(e)}), 502


@app.route("/api/sandboxes")
def list_sandboxes():
    try:
        with _channel() as ch:
            stub = pb_grpc.OpenShellStub(ch)
            resp = stub.ListSandboxes(pb.ListSandboxesRequest(limit=100), timeout=10)
            sandboxes = [_sandbox_to_dict(s) for s in resp.sandboxes]
            return jsonify({"sandboxes": sandboxes})
    except grpc.RpcError as e:
        return jsonify({"error": str(e)}), 502


@app.route("/api/sandboxes", methods=["POST"])
def create_sandbox():
    body = request.get_json(silent=True) or {}
    name = body.get("name", "")
    try:
        with _channel() as ch:
            stub = pb_grpc.OpenShellStub(ch)
            req = pb.CreateSandboxRequest(name=name, spec=dm.SandboxSpec())
            resp = stub.CreateSandbox(req, timeout=60)
            return jsonify({"sandbox": _sandbox_to_dict(resp.sandbox)}), 201
    except grpc.RpcError as e:
        return jsonify({"error": e.details()}), 502


@app.route("/api/sandboxes/<name>", methods=["DELETE"])
def delete_sandbox(name):
    try:
        with _channel() as ch:
            stub = pb_grpc.OpenShellStub(ch)
            resp = stub.DeleteSandbox(pb.DeleteSandboxRequest(name=name), timeout=15)
            return jsonify({"deleted": resp.deleted})
    except grpc.RpcError as e:
        return jsonify({"error": e.details()}), 502


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "5000")))
