# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY proto/ proto/

RUN python -m grpc_tools.protoc \
      -Iproto \
      --python_out=. \
      --grpc_python_out=. \
      proto/openshell.proto proto/datamodel.proto proto/sandbox.proto

COPY app.py .
COPY templates/ templates/

EXPOSE 5000

USER 1001

CMD ["python", "app.py"]
