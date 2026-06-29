"""Page crawler using Crawl4AI for clean markdown extraction.

Crawl4AI is an optional dependency — if not installed the crawler returns None
on every call and the rest of the pipeline continues with page metadata only.

Install:
    pip install crawl4ai
    crawl4ai-setup          # installs Playwright browsers
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass

from app.logging import get_logger

log = get_logger(__name__)


@dataclass
class CrawledPage:
    title: str
    markdown: str        # clean text, capped at 6 000 chars
    description: str


async def crawl(url: str, *, timeout: float = 10.0) -> CrawledPage | None:
    """Fetch a URL and return clean markdown + metadata.

    Returns None on any failure (missing dep, timeout, HTTP error, etc.).
    Always logs a warning so ops knows why crawling was skipped.
    """
    if not url or not url.startswith(("http://", "https://")):
        return None

    try:
        from crawl4ai import AsyncWebCrawler  # noqa: PLC0415
    except ImportError:
        log.debug("crawl4ai_not_installed — install with `pip install crawl4ai && crawl4ai-setup`")
        return None

    try:
        # Try the newer config-based API (crawl4ai ≥ 0.4). Fall back to the bare
        # arun() call for older installs. Both work the same from our perspective.
        async with AsyncWebCrawler(verbose=False) as crawler:
            try:
                from crawl4ai import BrowserConfig, CrawlerRunConfig, CacheMode  # noqa: PLC0415
                result = await asyncio.wait_for(
                    crawler.arun(
                        url=url,
                        config=CrawlerRunConfig(
                            cache_mode=CacheMode.BYPASS,
                            word_count_threshold=10,
                            excluded_tags=["nav", "footer", "aside", "header"],
                            remove_overlay_elements=True,
                            process_iframes=False,
                        ),
                    ),
                    timeout=timeout,
                )
            except (ImportError, TypeError):
                # Older API: no config kwarg.
                result = await asyncio.wait_for(
                    crawler.arun(url=url),
                    timeout=timeout,
                )

        if not result.success:
            log.warning("crawl_failed", url=url, err=getattr(result, "error_message", "unknown"))
            return None

        # Prefer fit_markdown (filtered, clean content), then raw markdown.
        md: str = ""
        if hasattr(result, "markdown_v2") and result.markdown_v2:
            mv2 = result.markdown_v2
            md = (getattr(mv2, "fit_markdown", None) or getattr(mv2, "raw_markdown", None) or "")
        if not md:
            md = getattr(result, "markdown", None) or ""

        meta: dict = getattr(result, "metadata", None) or {}

        return CrawledPage(
            title=(meta.get("title") or "").strip()[:200],
            markdown=md[:6_000].strip(),
            description=(meta.get("description") or "").strip()[:500],
        )

    except asyncio.TimeoutError:
        log.warning("crawl_timeout", url=url, timeout=timeout)
        return None
    except Exception as exc:  # noqa: BLE001
        log.warning("crawl_error", url=url, err=str(exc)[:300])
        return None
