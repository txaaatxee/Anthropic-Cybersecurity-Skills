#!/usr/bin/env python3
"""
Cybersecurity Analysis Agent - Claude API con herramientas de análisis de seguridad.
Integra inteligencia de amenazas, análisis de malware y búsqueda de vulnerabilidades.
"""

import json
import logging
import sys
from typing import Any

import anthropic
import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

client = anthropic.Anthropic()
MODEL = "claude-opus-4-8"

# ---------------------------------------------------------------------------
# Definición de herramientas
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "name": "analyze_hash",
        "description": (
            "Consulta MalwareBazaar (abuse.ch) para obtener información de inteligencia de amenazas "
            "sobre un hash de archivo (MD5, SHA-1 o SHA-256). Devuelve familia de malware, "
            "etiquetas, primer envío y estado de detección."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "file_hash": {
                    "type": "string",
                    "description": "Hash MD5, SHA-1 o SHA-256 del archivo a analizar.",
                }
            },
            "required": ["file_hash"],
        },
    },
    {
        "name": "lookup_cve",
        "description": (
            "Busca detalles de una vulnerabilidad CVE en la API pública de CIRCL (cve.circl.lu). "
            "Devuelve descripción, puntuación CVSS, referencias y productos afectados."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "cve_id": {
                    "type": "string",
                    "description": "Identificador CVE en formato CVE-YYYY-NNNNN (ej. CVE-2021-44228).",
                }
            },
            "required": ["cve_id"],
        },
    },
    {
        "name": "check_ransomware_decryptor",
        "description": (
            "Comprueba si el proyecto No More Ransom dispone de un descifrador gratuito "
            "para una familia de ransomware determinada."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "ransomware_family": {
                    "type": "string",
                    "description": "Nombre de la familia de ransomware (ej. LockBit, BlackCat, Conti).",
                }
            },
            "required": ["ransomware_family"],
        },
    },
    {
        "name": "get_mitre_technique",
        "description": (
            "Obtiene información sobre una técnica de MITRE ATT&CK mediante la API pública de MITRE. "
            "Devuelve nombre, tácticas asociadas, descripción y mitigaciones."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "technique_id": {
                    "type": "string",
                    "description": "ID de técnica ATT&CK (ej. T1486, T1059.001).",
                }
            },
            "required": ["technique_id"],
        },
    },
    {
        "name": "search_threat_intel",
        "description": (
            "Busca un Indicador de Compromiso (IOC) en la API pública de AlienVault OTX. "
            "Soporta direcciones IP, dominios y hashes de archivos."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "ioc": {
                    "type": "string",
                    "description": "El IOC a investigar (IP, dominio o hash).",
                },
                "ioc_type": {
                    "type": "string",
                    "enum": ["ip", "domain", "file"],
                    "description": "Tipo de IOC.",
                },
            },
            "required": ["ioc", "ioc_type"],
        },
    },
]

# ---------------------------------------------------------------------------
# Implementaciones de herramientas
# ---------------------------------------------------------------------------

def analyze_hash(file_hash: str) -> dict:
    """Consulta MalwareBazaar por hash de archivo."""
    try:
        resp = requests.post(
            "https://mb-api.abuse.ch/api/v1/",
            data={"query": "get_info", "hash": file_hash},
            timeout=20,
        )
        result = resp.json()
        if result.get("query_status") != "ok":
            return {"found": False, "message": f"Hash no encontrado: {result.get('query_status')}"}
        sample = result["data"][0]
        return {
            "found": True,
            "sha256": sample.get("sha256_hash"),
            "md5": sample.get("md5_hash"),
            "family": sample.get("signature") or "desconocida",
            "file_type": sample.get("file_type"),
            "file_size": sample.get("file_size"),
            "first_seen": sample.get("first_seen"),
            "tags": sample.get("tags") or [],
            "reporter": sample.get("reporter"),
        }
    except Exception as exc:
        return {"error": str(exc)}


def lookup_cve(cve_id: str) -> dict:
    """Obtiene detalles de CVE desde CIRCL."""
    try:
        resp = requests.get(
            f"https://cve.circl.lu/api/cve/{cve_id.upper()}",
            timeout=20,
        )
        if resp.status_code == 404:
            return {"found": False, "message": f"{cve_id} no encontrado."}
        data = resp.json()
        if not data:
            return {"found": False, "message": f"{cve_id} sin datos."}
        return {
            "found": True,
            "id": data.get("id"),
            "summary": data.get("summary"),
            "cvss": data.get("cvss"),
            "cvss3": data.get("cvss3"),
            "published": data.get("Published"),
            "modified": data.get("Modified"),
            "references": (data.get("references") or [])[:5],
            "vulnerable_configuration": [
                c.get("id") for c in (data.get("vulnerable_configuration") or [])[:5]
            ],
        }
    except Exception as exc:
        return {"error": str(exc)}


def check_ransomware_decryptor(ransomware_family: str) -> dict:
    """Verifica disponibilidad de descifrador en nomoreransom.org."""
    try:
        resp = requests.get(
            "https://www.nomoreransom.org/en/decryption-tools.html",
            timeout=20,
            headers={"User-Agent": "Mozilla/5.0 (SecurityResearch)"},
        )
        found = ransomware_family.lower() in resp.text.lower()
        return {
            "family": ransomware_family,
            "decryptor_available": found,
            "message": (
                f"Descifrador posiblemente disponible para {ransomware_family} en nomoreransom.org."
                if found
                else f"No se encontró descifrador para {ransomware_family} en nomoreransom.org."
            ),
            "url": "https://www.nomoreransom.org/en/decryption-tools.html",
        }
    except Exception as exc:
        return {"error": str(exc)}


def get_mitre_technique(technique_id: str) -> dict:
    """Obtiene datos de técnica ATT&CK desde la API de MITRE."""
    try:
        tid = technique_id.upper().replace(".", "%2F")
        resp = requests.get(
            f"https://attack.mitre.org/api/techniques/{tid}/",
            timeout=20,
            headers={"Accept": "application/json"},
        )
        if resp.status_code != 200:
            # Fallback: búsqueda en el índice de STIX de Enterprise ATT&CK
            stix_resp = requests.get(
                "https://raw.githubusercontent.com/mitre/cti/master/enterprise-attack/enterprise-attack.json",
                timeout=30,
            )
            stix_data = stix_resp.json()
            clean_id = technique_id.replace(".", "/")
            for obj in stix_data.get("objects", []):
                if obj.get("type") != "attack-pattern":
                    continue
                ext_refs = obj.get("external_references", [])
                for ref in ext_refs:
                    if ref.get("source_name") == "mitre-attack" and ref.get("external_id") == clean_id:
                        tactics = [
                            p["phase_name"]
                            for p in obj.get("kill_chain_phases", [])
                        ]
                        return {
                            "found": True,
                            "id": clean_id,
                            "name": obj.get("name"),
                            "description": (obj.get("description") or "")[:400] + "...",
                            "tactics": tactics,
                            "platforms": obj.get("x_mitre_platforms", []),
                        }
            return {"found": False, "message": f"Técnica {technique_id} no encontrada."}
        data = resp.json()
        return {"found": True, "raw": data}
    except Exception as exc:
        return {"error": str(exc)}


def search_threat_intel(ioc: str, ioc_type: str) -> dict:
    """Consulta AlienVault OTX para información de IOC (sin API key para datos básicos)."""
    try:
        type_map = {"ip": "IPv4", "domain": "domain", "file": "file"}
        otx_type = type_map.get(ioc_type, "IPv4")
        url = f"https://otx.alienvault.com/api/v1/indicators/{otx_type}/{ioc}/general"
        resp = requests.get(url, timeout=20, headers={"User-Agent": "Mozilla/5.0"})
        if resp.status_code == 404:
            return {"found": False, "ioc": ioc, "message": "IOC no encontrado en OTX."}
        data = resp.json()
        return {
            "found": True,
            "ioc": ioc,
            "type": ioc_type,
            "pulse_count": data.get("pulse_info", {}).get("count", 0),
            "reputation": data.get("reputation"),
            "country": data.get("country_name"),
            "asn": data.get("asn"),
            "malware_families": [
                p.get("name")
                for p in (data.get("pulse_info", {}).get("pulses") or [])[:3]
            ],
        }
    except Exception as exc:
        return {"error": str(exc)}


# ---------------------------------------------------------------------------
# Despachador de herramientas
# ---------------------------------------------------------------------------

TOOL_HANDLERS = {
    "analyze_hash": lambda args: analyze_hash(**args),
    "lookup_cve": lambda args: lookup_cve(**args),
    "check_ransomware_decryptor": lambda args: check_ransomware_decryptor(**args),
    "get_mitre_technique": lambda args: get_mitre_technique(**args),
    "search_threat_intel": lambda args: search_threat_intel(**args),
}


def execute_tool(tool_name: str, tool_input: dict) -> Any:
    handler = TOOL_HANDLERS.get(tool_name)
    if not handler:
        return {"error": f"Herramienta desconocida: {tool_name}"}
    logger.info("Ejecutando herramienta: %s | input: %s", tool_name, tool_input)
    result = handler(tool_input)
    logger.info("Resultado: %s", json.dumps(result, ensure_ascii=False)[:200])
    return result


# ---------------------------------------------------------------------------
# Bucle principal del agente
# ---------------------------------------------------------------------------

def run_agent(user_query: str) -> str:
    """Ejecuta el agente con pensamiento adaptativo y uso de herramientas."""
    messages = [{"role": "user", "content": user_query}]
    system_prompt = (
        "Eres un analista de ciberseguridad experto. Tienes acceso a herramientas de "
        "inteligencia de amenazas, análisis de malware y búsqueda de vulnerabilidades. "
        "Usa las herramientas para obtener datos reales antes de emitir conclusiones. "
        "Responde siempre en español con análisis claros y accionables."
    )

    while True:
        response = client.messages.create(
            model=MODEL,
            max_tokens=8096,
            thinking={"type": "adaptive"},
            system=system_prompt,
            tools=TOOLS,
            messages=messages,
        )

        # Agregar respuesta del asistente al historial
        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason == "end_turn":
            # Extraer texto final
            for block in response.content:
                if hasattr(block, "text"):
                    return block.text
            return ""

        if response.stop_reason != "tool_use":
            break

        # Procesar llamadas a herramientas
        tool_results = []
        for block in response.content:
            if block.type != "tool_use":
                continue
            result = execute_tool(block.name, block.input)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": block.id,
                "content": json.dumps(result, ensure_ascii=False),
            })

        if tool_results:
            messages.append({"role": "user", "content": tool_results})

    return "El agente no pudo generar una respuesta."


# ---------------------------------------------------------------------------
# Interfaz de línea de comandos
# ---------------------------------------------------------------------------

BANNER = """
╔══════════════════════════════════════════════════════════════╗
║     Agente de Ciberseguridad — Powered by Claude API         ║
║  Herramientas: MalwareBazaar · CVE · MITRE ATT&CK · OTX     ║
╚══════════════════════════════════════════════════════════════╝
Escribe tu consulta de seguridad o 'salir' para terminar.

Ejemplos:
  • Analiza el hash abc123... ¿es malware conocido?
  • ¿Qué es CVE-2021-44228 y qué sistemas afecta?
  • Explica la técnica T1486 de MITRE ATT&CK
  • Busca inteligencia de amenazas para la IP 1.2.3.4
  • ¿Hay descifrador disponible para LockBit?
"""


def main():
    print(BANNER)

    # Modo no interactivo: consulta desde argumento
    if len(sys.argv) > 1:
        query = " ".join(sys.argv[1:])
        print(f"\n[Consulta] {query}\n")
        answer = run_agent(query)
        print(answer)
        return

    # Modo interactivo
    while True:
        try:
            query = input("\n>> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nSaliendo...")
            break

        if not query:
            continue
        if query.lower() in {"salir", "exit", "quit"}:
            print("¡Hasta luego!")
            break

        print()
        answer = run_agent(query)
        print(answer)


if __name__ == "__main__":
    main()
