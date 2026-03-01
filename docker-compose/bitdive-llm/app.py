import os
import fnmatch
import json
import re
import threading
from pathlib import Path
from typing import Optional, List, Any, Union, Dict

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from huggingface_hub import hf_hub_download, list_repo_files
from llama_cpp import Llama

# =========================
# ENV / настройки
# =========================
HF_REPO_ID = os.getenv("HF_REPO_ID", "bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF")
HF_TOKEN = os.getenv("HF_TOKEN")  # optional
MODEL_DIR = Path(os.getenv("MODEL_DIR", "/models"))
MODEL_FILENAME = os.getenv("MODEL_FILENAME", "").strip()  # exact filename (optional)
MODEL_GLOB = os.getenv("MODEL_GLOB", "*Q4_K_S*.gguf")     # mask if MODEL_FILENAME is empty

# Оставь пустым для авто-режима, например: CHAT_FORMAT=""
# Если хочешь зафиксировать, можно "chatml"
CHAT_FORMAT = os.getenv("CHAT_FORMAT", "").strip()

N_CTX = int(os.getenv("N_CTX", "8192"))
N_THREADS = int(os.getenv("N_THREADS", "8"))
N_GPU_LAYERS = int(os.getenv("N_GPU_LAYERS", "0"))  # 0=CPU, -1=все слои в GPU (если CUDA-сборка)
VERBOSE = os.getenv("LLAMA_VERBOSE", "false").lower() == "true"

app = FastAPI(title="DeepSeek Coder V2 Lite GGUF API")

llm: Optional[Llama] = None
llm_lock = threading.Lock()
loaded_model_path: Optional[Path] = None


# =========================
# Схемы запросов/ответов
# =========================
class GenerateRequest(BaseModel):
    prompt: str = Field(..., min_length=1)

    # Новое: system можно передавать строкой ИЛИ объектом (как у тебя)
    system: Optional[Union[str, Dict[str, Any]]] = None

    temperature: float = 0.1
    max_tokens: int = 512


class GenerateResponse(BaseModel):
    content: Union[str, Dict[str, Any]]  # чистый JSON-объект или строка при ошибке парсинга
    gguf_path: str


# =========================
# Helpers: извлечение JSON из ответа модели
# =========================
def extract_json_from_content(raw: str) -> str:
    """
    Убирает обёртку markdown (```json ... ```) и возвращает только строку с JSON.
    """
    text = raw.strip()
    # Убираем блок ```json ... ``` или ``` ... ```
    match = re.search(r"^```(?:json)?\s*\n?(.*?)\n?```\s*$", text, re.DOTALL)
    if match:
        return match.group(1).strip()
    return text


def parse_content_as_json(raw: str) -> Union[Dict[str, Any], str]:
    """
    Пытается извлечь и распарсить JSON из ответа модели.
    Возвращает dict при успехе, иначе очищенную строку.
    """
    extracted = extract_json_from_content(raw)
    try:
        return json.loads(extracted)
    except json.JSONDecodeError:
        return extracted


# =========================
# Helpers: system prompt builder
# =========================
def _pretty_json_inline(data: Any) -> str:
    try:
        return json.dumps(data, ensure_ascii=False)
    except Exception:
        return str(data)


def build_system_prompt(system_value: Optional[Union[str, Dict[str, Any]]]) -> str:
    """
    Преобразует system (строку или объект) в текстовый system prompt для LLM.
    """
    default_system = "You are a coding assistant. Return concise production-quality code."

    if system_value is None:
        return default_system

    if isinstance(system_value, str):
        return system_value

    if not isinstance(system_value, dict):
        return f"{default_system}\n\nAdditional system context: {_pretty_json_inline(system_value)}"

    lines: List[str] = []

    role = system_value.get("role")
    instructions = system_value.get("instructions")
    rules = system_value.get("rules")

    if role:
        lines.append(f"Role: {role}")

    if isinstance(instructions, dict):
        objective = instructions.get("objective")
        output_format = instructions.get("output_format")
        language = instructions.get("language")
        schema = instructions.get("schema")

        if objective:
            lines.append(f"Objective: {objective}")
        if output_format:
            lines.append(f"Output format: {output_format}")
        if language:
            lines.append(f"Language: {language}")

        if schema:
            lines.append("Required schema:")
            if isinstance(schema, dict):
                for k, v in schema.items():
                    lines.append(f"- {k}: {v}")
            else:
                lines.append(_pretty_json_inline(schema))
    elif instructions is not None:
        lines.append(f"Instructions: {_pretty_json_inline(instructions)}")

    if isinstance(rules, list) and rules:
        lines.append("Rules:")
        for rule in rules:
            lines.append(f"- {rule}")
    elif rules is not None:
        lines.append(f"Rules: {_pretty_json_inline(rules)}")

    if not lines:
        return default_system

    # Усиливаем дисциплину вывода, если пользователь просит JSON
    lines.append("Important: Follow the requested output format strictly.")
    return "\n".join(lines)


# =========================
# Логика поиска/скачивания GGUF
# =========================
def _local_candidates(model_dir: Path, pattern: str) -> List[Path]:
    if not model_dir.exists():
        return []
    candidates: List[Path] = []
    for p in model_dir.rglob("*.gguf"):
        if fnmatch.fnmatch(p.name, pattern):
            candidates.append(p)
    return sorted(candidates, key=lambda x: x.name.lower())


def find_local_model(model_dir: Path, filename: str, pattern: str) -> Optional[Path]:
    model_dir.mkdir(parents=True, exist_ok=True)

    # 1) exact filename
    if filename:
        exact = model_dir / filename
        if exact.exists():
            return exact

        # вдруг лежит во вложенной папке
        for p in model_dir.rglob(filename):
            if p.is_file():
                return p

    # 2) поиск по маске
    candidates = _local_candidates(model_dir, pattern)
    if candidates:
        # Берем самый большой файл (обычно нужный квант)
        candidates = sorted(candidates, key=lambda p: p.stat().st_size, reverse=True)
        return candidates[0]

    return None


def choose_remote_filename(repo_id: str, filename: str, pattern: str, token: Optional[str]) -> str:
    if filename:
        return filename

    print(f"[INFO] Listing files in HF repo: {repo_id}")
    files = list_repo_files(repo_id=repo_id, repo_type="model", token=token)

    ggufs = [f for f in files if f.lower().endswith(".gguf")]
    matched = [f for f in ggufs if fnmatch.fnmatch(Path(f).name, pattern)]

    if not matched:
        raise RuntimeError(
            f"Не найден GGUF по маске '{pattern}' в '{repo_id}'. "
            f"Доступные GGUF: {[Path(x).name for x in ggufs[:100]]}"
        )

    # Предпочитаем файлы в корне репозитория
    matched = sorted(matched, key=lambda x: (x.count("/"), len(x), x.lower()))
    chosen = matched[0]
    print(f"[INFO] Selected remote GGUF: {chosen}")
    return chosen


def download_model_if_needed() -> Path:
    MODEL_DIR.mkdir(parents=True, exist_ok=True)

    local = find_local_model(MODEL_DIR, MODEL_FILENAME, MODEL_GLOB)
    if local:
        print(f"[OK] Local model found: {local}")
        return local

    print("[INFO] Local model not found. Downloading from Hugging Face...")

    remote_filename = choose_remote_filename(
        repo_id=HF_REPO_ID,
        filename=MODEL_FILENAME,
        pattern=MODEL_GLOB,
        token=HF_TOKEN
    )

    downloaded_path = hf_hub_download(
        repo_id=HF_REPO_ID,
        filename=remote_filename,
        repo_type="model",
        local_dir=str(MODEL_DIR),
        token=HF_TOKEN,
    )

    downloaded = Path(downloaded_path)
    print(f"[OK] Downloaded model to: {downloaded}")

    # Повторная проверка через общий поиск
    local = find_local_model(MODEL_DIR, MODEL_FILENAME or downloaded.name, MODEL_GLOB)
    return local or downloaded


# =========================
# Загрузка модели llama.cpp
# =========================
def load_llm() -> None:
    global llm, loaded_model_path

    if llm is not None:
        return

    model_path = download_model_if_needed()

    print("[INFO] Loading GGUF model into llama.cpp...")
    print(f"       path={model_path}")
    print(f"       n_ctx={N_CTX}, n_threads={N_THREADS}, n_gpu_layers={N_GPU_LAYERS}, chat_format={CHAT_FORMAT or 'AUTO'}")

    llama_kwargs = dict(
        model_path=str(model_path),
        n_ctx=N_CTX,
        n_threads=N_THREADS,
        n_gpu_layers=N_GPU_LAYERS,
        verbose=VERBOSE,
    )

    # Передаем chat_format только если задан
    if CHAT_FORMAT:
        llama_kwargs["chat_format"] = CHAT_FORMAT

    try:
        llm_instance = Llama(**llama_kwargs)
    except Exception as e:
        # Если проблема в chat_format, пробуем auto fallback
        if CHAT_FORMAT and "Invalid chat handler" in str(e):
            print(f"[WARN] Invalid chat handler '{CHAT_FORMAT}', fallback to AUTO")
            llama_kwargs.pop("chat_format", None)
            llm_instance = Llama(**llama_kwargs)
        else:
            raise

    llm = llm_instance
    loaded_model_path = model_path
    print("[OK] Model loaded")


# =========================
# FastAPI lifecycle
# =========================
@app.on_event("startup")
def on_startup():
    try:
        load_llm()
    except Exception as e:
        print(f"[ERROR] Startup failed: {e}")
        raise


# =========================
# API endpoints
# =========================
@app.get("/health")
def health():
    return {
        "status": "ok",
        "loaded": llm is not None,
        "gguf_path": str(loaded_model_path) if loaded_model_path else None,
        "chat_format": CHAT_FORMAT or "AUTO",
        "n_ctx": N_CTX,
        "n_threads": N_THREADS,
        "n_gpu_layers": N_GPU_LAYERS,
    }


@app.post("/generate", response_model=GenerateResponse)
def generate(req: GenerateRequest):
    if llm is None:
        raise HTTPException(status_code=503, detail="Model is not loaded")

    system_prompt = build_system_prompt(req.system)

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": req.prompt},
    ]

    try:
        with llm_lock:
            resp = llm.create_chat_completion(
                messages=messages,
                temperature=req.temperature,
                max_tokens=req.max_tokens,
            )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Generation failed: {e}")

    try:
        raw_content = resp["choices"][0]["message"]["content"]
    except Exception:
        raw_content = str(resp)

    # Возвращаем чистый JSON: убираем ```json ... ``` и парсим в объект
    content = parse_content_as_json(raw_content)

    return GenerateResponse(
        content=content,
        gguf_path=str(loaded_model_path) if loaded_model_path else ""
    )