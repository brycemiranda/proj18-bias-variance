#!/usr/bin/env python3
import os, json
import pandas as pd
import boto3
import psycopg2
from io import BytesIO
from datetime import datetime

BUCKET      = os.environ['BUCKET_NAME']
S3_ENDPOINT = os.environ['S3_ENDPOINT']
AWS_KEY     = os.environ['AWS_ACCESS_KEY_ID']
AWS_SECRET  = os.environ['AWS_SECRET_ACCESS_KEY']
PG_HOST     = os.environ.get('POSTGRES_HOST', 'postgres.platform.svc.cluster.local')
PG_USER     = os.environ['POSTGRES_USER']
PG_PASS     = os.environ['POSTGRES_PASSWORD']
PG_DB       = os.environ['POSTGRES_DB']

def s3():
    return boto3.client('s3', endpoint_url=S3_ENDPOINT,
                        aws_access_key_id=AWS_KEY,
                        aws_secret_access_key=AWS_SECRET)

def pg():
    return psycopg2.connect(host=PG_HOST, user=PG_USER,
                            password=PG_PASS, dbname=PG_DB)

def fetch_production_events():
    print("Fetching production events from PostgreSQL...")
    conn = pg()
    df = pd.read_sql("""
        SELECT user_id, recipe_id, event_type, rating, weight, timestamp
        FROM mealie_events
        WHERE weight != 0.0
        ORDER BY timestamp ASC
    """, conn)
    conn.close()
    print(f"  ✓ {len(df):,} events fetched")
    return df

def fetch_foodcom_base():
    print("Loading Food.com base interactions from object storage...")
    obj = s3().get_object(Bucket=BUCKET,
                          Key='processed/interactions_clean.parquet')
    interactions = pd.read_parquet(BytesIO(obj['Body'].read()))
    interactions['source']    = 'foodcom'
    interactions['user_id']   = interactions['user_id'].astype(str)
    interactions['recipe_id'] = interactions['recipe_id'].astype(str)

    # Join tags from recipes_clean so nightly_eval can compute per-tier NDCG
    print("  Joining recipe tags onto interactions...")
    try:
        obj_r = s3().get_object(Bucket=BUCKET, Key='processed/recipes_clean.parquet')
        recipes = pd.read_parquet(BytesIO(obj_r['Body'].read()),
                                  columns=['recipe_id', 'tags'])
        recipes['recipe_id'] = recipes['recipe_id'].astype(str)
        interactions = interactions.merge(recipes, on='recipe_id', how='left')
        interactions['tags'] = interactions['tags'].apply(
            lambda t: t if isinstance(t, list) else []
        )
        print(f"  ✓ Tags joined ({interactions['tags'].apply(len).mean():.1f} tags/interaction avg)")
    except Exception as e:
        print(f"  [WARN] Could not join tags: {e} — tags column will be missing")
        interactions['tags'] = [[] for _ in range(len(interactions))]

    print(f"  ✓ {len(interactions):,} Food.com interactions loaded")
    return interactions

def candidate_selection(df):
    print("Applying candidate selection...")
    df = df[df['weight'] != 0.0]
    user_counts = df.groupby('user_id').size()
    valid = user_counts[user_counts >= 3].index
    df = df[df['user_id'].isin(valid)]
    print(f"  ✓ {len(df):,} events kept")
    print(f"  ✓ {df['user_id'].nunique():,} unique users")
    return df

def chronological_split(df):
    # Per-user temporal split: for each user with >= 5 interactions, put the last
    # 1-2 interactions in val and all earlier ones in train. This guarantees every
    # val user also has train data (overlap), fixing NDCG collapse caused by val
    # users having no ALS embeddings.
    print("Per-user temporal split (last 1-2 interactions → val, rest → train)...")
    train_parts, val_parts = [], []

    for _, user_df in df.groupby('user_id'):
        user_df = user_df.sort_values('timestamp')
        n = len(user_df)
        if n >= 5:
            # Take last 2 for heavy users, last 1 for lighter users; always keep >= 3 in train
            n_val = 2 if n >= 10 else 1
            train_parts.append(user_df.iloc[:-n_val])
            val_parts.append(user_df.iloc[-n_val:])
        else:
            train_parts.append(user_df)

    train = pd.concat(train_parts, ignore_index=True)
    val = pd.concat(val_parts, ignore_index=True) if val_parts else pd.DataFrame(columns=df.columns)
    overlap = len(set(train['user_id']) & set(val['user_id']))
    print(f"  Train: {len(train):,} rows | {train['user_id'].nunique():,} users")
    print(f"  Val:   {len(val):,} rows | {val['user_id'].nunique():,} users")
    print(f"  Overlapping users: {overlap:,}")
    val_pos = (val['rating'] >= 4).sum() if 'rating' in val.columns else 'n/a'
    print(f"  Val positive ratings (>=4): {val_pos:,}" if isinstance(val_pos, int) else f"  Val positive ratings: {val_pos}")
    return train, val

def upload_versioned(client, train, val, version):
    def up(df, key):
        buf = BytesIO()
        df.to_parquet(buf, index=False); buf.seek(0)
        client.put_object(Bucket=BUCKET, Key=key, Body=buf.getvalue())
        print(f"  ✓ Uploaded {key}")

    up(train, f'datasets/{version}/train.parquet')
    up(val,   f'datasets/{version}/val.parquet')

    meta = {
        'version': version,
        'train_rows': len(train),
        'val_rows': len(val),
        'unique_users_train': int(train['user_id'].nunique()),
        'created_at': datetime.utcnow().isoformat(),
        'split_method': 'per_user_temporal',
        'unique_users_val': int(val['user_id'].nunique()),
    }
    client.put_object(Bucket=BUCKET,
                      Key=f'datasets/{version}/meta.json',
                      Body=json.dumps(meta, indent=2))
    print(f"  ✓ Metadata written")
    print(f"  {json.dumps(meta, indent=2)}")

def main():
    version = f"v2_{datetime.today().strftime('%Y-%m-%d')}"
    print(f"=== Batch Pipeline | version: {version} ===\n")

    client = s3()

    # Get production events from PostgreSQL
    prod = fetch_production_events()
    prod['timestamp'] = pd.to_datetime(prod['timestamp'])
    prod['source'] = 'production'

    # Get Food.com base
    foodcom = fetch_foodcom_base()
    foodcom['timestamp'] = pd.to_datetime(foodcom['date'])

    # Combine
    combined = pd.concat([foodcom, prod], ignore_index=True)

    # Candidate selection
    selected = candidate_selection(combined)

    # Chronological split
    train, val = chronological_split(selected)

    # Upload versioned datasets
    upload_versioned(client, train, val, version)

    print(f"\n✅ Batch pipeline complete! Version: {version}")

if __name__ == '__main__':
    main()
