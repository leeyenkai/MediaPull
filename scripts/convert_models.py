"""Converts the analysis models to Core ML (SPEC section 36, D-58, D-67).

Run by scripts/convert-models.sh inside a throwaway virtual environment; never bundled.
Usage: convert_models.py <models cache folder> [step ...]   steps: mobileclip, adaface, scrfd
"""

import os
import sys
import warnings

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F

warnings.filterwarnings("ignore")
ROOT = sys.argv[1]
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "converted")
TARGET = ct.target.macOS15

MOBILECLIP_REVISION = "2a5959ca5d2fe6790809a77e5b520c9e69ae95ed"
ADAFACE_REVISION = "54f602a0737bd1ee4a4e7e9fd089a485f397fefd"


def save(model, name):
    path = os.path.join(OUT, name + ".mlpackage")
    model.save(path)
    print("saved", path)


def convert_mobileclip():
    """MobileCLIP2-S3: 768-d image and text embeddings, OpenAI mean and std baked into the image graph."""
    import open_clip
    from huggingface_hub import hf_hub_download
    from timm.utils import reparameterize_model

    weights = hf_hub_download("timm/MobileCLIP2-S3-OpenCLIP", "open_clip_model.safetensors", revision=MOBILECLIP_REVISION,
                              cache_dir=os.path.join(SRC, "hf"))
    model, _, _ = open_clip.create_model_and_transforms("MobileCLIP2-S3", pretrained=weights)
    model = reparameterize_model(model.eval()).requires_grad_(False)
    mean = torch.tensor([0.48145466, 0.4578275, 0.40821073]).view(1, 3, 1, 1)
    std = torch.tensor([0.26862954, 0.26130258, 0.27577711]).view(1, 3, 1, 1)

    class Image(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.m = model
            self.register_buffer("mean", mean)
            self.register_buffer("std", std)

        def forward(self, x):
            return F.normalize(self.m.encode_image((x - self.mean) / self.std), dim=-1)

    class Text(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.m = model

        def forward(self, ids):
            return F.normalize(self.m.encode_text(ids), dim=-1)

    tokens = open_clip.get_tokenizer("MobileCLIP2-S3")(["a photo of a dog"]).to(torch.int32)
    with torch.no_grad():
        image = torch.jit.trace(Image().eval(), torch.rand(1, 3, 256, 256))
        text = torch.jit.trace(Text().eval(), tokens)
        reference = {"tokens": tokens.tolist(), "text": Text()(tokens).tolist()}
    save(ct.convert(image, inputs=[ct.ImageType(name="image", shape=(1, 3, 256, 256), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
                    outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=TARGET,
                    compute_precision=ct.precision.FLOAT16), "mobileclip2_s3_image")
    # The text tower's LayerNorms are checked in fp16 against PyTorch below; fp32 is used if fp16 drifts.
    for precision, name in [(ct.precision.FLOAT16, "fp16"), (ct.precision.FLOAT32, "fp32")]:
        ml = ct.convert(text, inputs=[ct.TensorType(name="text", shape=(1, 77), dtype=np.int32)],
                        outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=TARGET, compute_precision=precision)
        out = np.array(ml.predict({"text": tokens.numpy().astype(np.int32)})["embedding"]).ravel()
        cosine = float(out @ np.array(reference["text"]).ravel() / np.linalg.norm(out))
        print(f"text tower {name}: cosine to PyTorch {cosine:.5f}")
        if cosine > 0.999 or name == "fp32":
            save(ml, "mobileclip2_s3_text")
            break
    tok = open_clip.get_tokenizer("MobileCLIP2-S3")
    print("tokenizer:", type(tok).__name__, tok(["café crème, naïve résumé"]).tolist()[0][:10])


def convert_adaface():
    """AdaFace IR-101 trained on WebFace12M (CVLFace release): 512-d face embeddings from aligned 112 × 112 crops."""
    from huggingface_hub import snapshot_download
    from safetensors.torch import load_file

    path = snapshot_download("minchul/cvlface_adaface_ir101_webface12m", revision=ADAFACE_REVISION, cache_dir=os.path.join(SRC, "hf"))
    sys.path.insert(0, path)
    # The model file imports fvcore only to count FLOPs; a stand-in avoids installing it.
    import types
    fvcore = types.ModuleType("fvcore")
    fvcore.nn = types.ModuleType("fvcore.nn")
    fvcore.nn.flop_count = lambda *a, **k: ({}, {})
    sys.modules.setdefault("fvcore", fvcore)
    sys.modules.setdefault("fvcore.nn", fvcore.nn)
    from models.iresnet.model import IR_101

    net = IR_101(input_size=(112, 112), output_dim=512)
    state = {k[len("model.net."):]: v for k, v in load_file(os.path.join(path, "model.safetensors")).items() if k.startswith("model.net.")}
    print(net.load_state_dict(state, strict=True))
    net.eval().requires_grad_(False)

    for order in ("rgb", "bgr"):
        class Face(torch.nn.Module):
            def __init__(self, flip):
                super().__init__()
                self.n = net
                self.flip = flip

            def forward(self, x):  # x: RGB in 0...1
                if self.flip:
                    x = x[:, [2, 1, 0], :, :]
                return F.normalize(self.n((x - 0.5) / 0.5), dim=-1)

        with torch.no_grad():
            traced = torch.jit.trace(Face(order == "bgr").eval(), torch.rand(1, 3, 112, 112))
        save(ct.convert(traced, inputs=[ct.TensorType(name="face", shape=(1, 3, 112, 112))], outputs=[ct.TensorType(name="embedding")],
                        minimum_deployment_target=TARGET, compute_precision=ct.precision.FLOAT16), f"adaface_ir101_{order}")


def convert_scrfd():
    """SCRFD-10G with five landmarks (det_10g.onnx): faces and landmarks for alignment, decoded in Swift."""
    import zipfile

    import onnx
    import onnx2torch

    archive = os.path.join(SRC, "buffalo_l.zip")
    onnx_path = os.path.join(SRC, "det_10g.onnx")
    if not os.path.exists(onnx_path):
        with zipfile.ZipFile(archive) as z:
            name = next(n for n in z.namelist() if n.endswith("det_10g.onnx"))
            with open(onnx_path, "wb") as f:
                f.write(z.read(name))
    model = onnx.load(onnx_path)
    dims = model.graph.input[0].type.tensor_type.shape.dim
    dims[0].dim_value, dims[2].dim_value, dims[3].dim_value = 1, 640, 640
    print("outputs:", [o.name for o in model.graph.output])
    net = onnx2torch.convert(model).eval().requires_grad_(False)
    with torch.no_grad():
        traced = torch.jit.trace(net, torch.zeros(1, 3, 640, 640))
        shapes = [tuple(t.shape) for t in net(torch.zeros(1, 3, 640, 640))]
    print("output shapes:", shapes)
    names = [f"out{i}" for i in range(len(shapes))]
    ml = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=(1, 3, 640, 640), scale=1 / 128.0, bias=[-127.5 / 128] * 3,
                                                 color_layout=ct.colorlayout.RGB)],
                    outputs=[ct.TensorType(name=n) for n in names], minimum_deployment_target=TARGET,
                    compute_precision=ct.precision.FLOAT16)
    save(ml, "scrfd_10g")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for step in sys.argv[2:] or ["mobileclip", "adaface", "scrfd"]:
        globals()["convert_" + step]()
