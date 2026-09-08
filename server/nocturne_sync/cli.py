"""Administration is deliberately command line only.

There is no HTTP route that creates studies, enrols participants or mints researcher
tokens. Anything that can grant read access to a study's health data requires shell access
to the host, which is a much smaller attack surface than an admin endpoint and one less
thing to get wrong.
"""

from __future__ import annotations

import argparse
import datetime as dt
import secrets
import sys

from sqlalchemy import delete, select

from .auth import hash_token, mint_token
from .db import (
    ContextSample,
    HeartbeatSeries,
    NightAnalysis,
    Participant,
    SessionLocal,
    SleepInterval,
    Study,
    Token,
    init_db,
    utcnow,
)


def cmd_create_study(args: argparse.Namespace) -> int:
    with SessionLocal() as db:
        if db.get(Study, args.id) is not None:
            print(f"study {args.id} already exists", file=sys.stderr)
            return 1
        db.add(Study(id=args.id, name=args.name, retention_days=args.retention_days))
        db.commit()
    print(f"created study {args.id}")
    return 0


def cmd_add_participants(args: argparse.Namespace) -> int:
    """Create participant codes and print their one-time enrolment secrets.

    The secrets are shown once. Hand each one to its participant over whatever channel the
    consent process already uses; they are typed into the app on enrolment and then dead.
    """
    with SessionLocal() as db:
        if db.get(Study, args.study) is None:
            print(f"unknown study {args.study}", file=sys.stderr)
            return 1
        print("participant_code,enrolment_secret")
        for n in range(args.count):
            code = f"{args.prefix}{args.start + n:03d}"
            if db.get(Participant, code) is not None:
                print(f"# {code} already exists, skipped", file=sys.stderr)
                continue
            secret = secrets.token_urlsafe(12)
            db.add(
                Participant(
                    code=code,
                    study_id=args.study,
                    enrolment_secret_hash=hash_token(secret),
                )
            )
            print(f"{code},{secret}")
        db.commit()
    return 0


def cmd_mint_researcher(args: argparse.Namespace) -> int:
    with SessionLocal() as db:
        if args.study and db.get(Study, args.study) is None:
            print(f"unknown study {args.study}", file=sys.stderr)
            return 1
        plaintext, digest = mint_token()
        expires = (
            utcnow() + dt.timedelta(days=args.expires_days) if args.expires_days else None
        )
        db.add(
            Token(
                token_hash=digest,
                scope="researcher",
                study_id=args.study,
                label=args.label,
                expires_at=expires,
            )
        )
        db.commit()
    print("Researcher token (shown once, store it in a password manager):")
    print(plaintext)
    return 0


def cmd_revoke(args: argparse.Namespace) -> int:
    with SessionLocal() as db:
        row = db.scalar(select(Token).where(Token.token_hash == hash_token(args.token)))
        if row is None:
            print("token not found", file=sys.stderr)
            return 1
        row.revoked_at = utcnow()
        db.commit()
    print("revoked")
    return 0


def cmd_withdraw(args: argparse.Namespace) -> int:
    """Mark a participant withdrawn, and optionally purge their data.

    Which of these your consent form promised matters. "You may withdraw at any time" and
    "you may withdraw and have your data deleted" are different commitments, so the purge
    is a separate explicit flag rather than the default.
    """
    with SessionLocal() as db:
        participant = db.get(Participant, args.code)
        if participant is None:
            print("unknown participant", file=sys.stderr)
            return 1
        participant.withdrawn_at = utcnow()
        for token in db.scalars(
            select(Token).where(Token.participant_code == args.code, Token.revoked_at.is_(None))
        ):
            token.revoked_at = utcnow()
        removed = 0
        if args.purge:
            for model in (HeartbeatSeries, SleepInterval, ContextSample, NightAnalysis):
                removed += db.execute(
                    delete(model).where(model.participant_code == args.code)
                ).rowcount or 0
        db.commit()
    print(f"withdrew {args.code}; tokens revoked" + (f"; purged {removed} rows" if args.purge else ""))
    return 0


def cmd_prune(args: argparse.Namespace) -> int:
    """Delete rows older than each study's retention_days. Dry run unless --apply."""
    with SessionLocal() as db:
        total = 0
        for study in db.scalars(select(Study)):
            if not study.retention_days:
                continue
            cutoff = utcnow() - dt.timedelta(days=study.retention_days)
            codes = list(
                db.scalars(select(Participant.code).where(Participant.study_id == study.id))
            )
            if not codes:
                continue
            for model, column in (
                (HeartbeatSeries, HeartbeatSeries.start),
                (SleepInterval, SleepInterval.start),
                (ContextSample, ContextSample.start),
            ):
                stmt = select(model).where(model.participant_code.in_(codes), column < cutoff)
                rows = db.scalars(stmt).all()
                total += len(rows)
                if args.apply:
                    for row in rows:
                        db.delete(row)
            print(f"{study.id}: retention {study.retention_days}d, cutoff {cutoff.date()}")
        if args.apply:
            db.commit()
        print(f"{'deleted' if args.apply else 'would delete'} {total} rows")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="nocturne-admin")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("init", help="create tables")
    p.set_defaults(func=lambda a: (init_db(), print("schema ready"), 0)[2])

    p = sub.add_parser("create-study")
    p.add_argument("id")
    p.add_argument("--name", default="")
    p.add_argument("--retention-days", type=int, default=None)
    p.set_defaults(func=cmd_create_study)

    p = sub.add_parser("add-participants", help="mint participant codes and enrolment secrets")
    p.add_argument("--study", required=True)
    p.add_argument("--count", type=int, required=True)
    p.add_argument("--prefix", default="P")
    p.add_argument("--start", type=int, default=1)
    p.set_defaults(func=cmd_add_participants)

    p = sub.add_parser("mint-researcher-token")
    p.add_argument("--label", required=True)
    p.add_argument("--study", default=None, help="scope the token to one study")
    p.add_argument("--expires-days", type=int, default=None)
    p.set_defaults(func=cmd_mint_researcher)

    p = sub.add_parser("revoke")
    p.add_argument("token")
    p.set_defaults(func=cmd_revoke)

    p = sub.add_parser("withdraw")
    p.add_argument("code")
    p.add_argument("--purge", action="store_true", help="also delete the participant's data")
    p.set_defaults(func=cmd_withdraw)

    p = sub.add_parser("prune", help="apply each study's retention policy")
    p.add_argument("--apply", action="store_true")
    p.set_defaults(func=cmd_prune)

    args = parser.parse_args(argv)
    init_db()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
