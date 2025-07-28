import logging

import pytest
import torch

import llm_speculative_decoding_gpt2 as specdec


class _DummyModelManager:
    def __init__(self) -> None:
        self.tokenizer = object()
        self.target_model = object()
        self.draft_model = object()


def _make_decoder() -> specdec.SpeculativeDecoder:
    config = specdec.SpeculativeDecodingConfig()
    logger = logging.getLogger("specdec-test")
    logger.addHandler(logging.NullHandler())
    return specdec.SpeculativeDecoder(config, _DummyModelManager(), logger)


def test_acceptance_rate_and_speedup() -> None:
    metrics = specdec.SpeculationMetrics(
        total_speculation_rounds=5,
        total_speculated_tokens=10,
        total_accepted_tokens=5,
        total_tokens_generated=5,
        total_inference_time=2.0,
    )
    assert metrics.acceptance_rate == pytest.approx(0.5)
    assert metrics.tokens_per_second == pytest.approx(2.5)
    assert metrics.speedup_ratio == pytest.approx(1.5)


def test_acceptance_rate_zero_when_no_speculation() -> None:
    metrics = specdec.SpeculationMetrics()
    assert metrics.acceptance_rate == 0.0
    assert metrics.speedup_ratio == 1.0


def test_greedy_sampling_returns_argmax() -> None:
    decoder = _make_decoder()
    logits = torch.tensor([0.1, 0.2, 0.3])
    token = decoder._sample_token_id(logits, temperature=1.0, top_p=1.0, top_k=0)
    assert token == 2


def test_top_p_forces_top_token() -> None:
    decoder = _make_decoder()
    logits = torch.tensor([10.0, 0.0, 0.0])
    token = decoder._sample_token_id(logits, temperature=1.0, top_p=0.5, top_k=0)
    assert token == 0


def test_top_k_limits_choices() -> None:
    decoder = _make_decoder()
    torch.manual_seed(0)
    logits = torch.tensor([0.1, 0.2, 0.3, 0.4])
    token = decoder._sample_token_id(logits, temperature=1.0, top_p=1.0, top_k=2)
    assert token in {2, 3}
