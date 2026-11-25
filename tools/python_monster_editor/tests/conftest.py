from pathlib import Path

import pytest

from rtcmonster import MonsterDocument, read_document

TOOL = Path(__file__).resolve().parents[1]
PROJECT = TOOL.parents[1]
EXAMPLES = TOOL / "examples"
EXAMPLE_IDS = ("sewer_beetle", "frog", "sewer_rat_prototype")


def load(name):
    return read_document(EXAMPLES / f"{name}.rtcmonster")[0]


def edit(document, change):
    """Return a copy of the document after ``change(data)`` mutated its plain data."""
    data = document.to_dict()
    change(data)
    return MonsterDocument(data)


@pytest.fixture
def beetle():
    return load("sewer_beetle")


@pytest.fixture
def frog():
    return load("frog")


@pytest.fixture
def rat():
    return load("sewer_rat_prototype")
