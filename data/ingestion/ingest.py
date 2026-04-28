#!/usr/bin/env python3
import os, json, subprocess, ast
import pandas as pd
import numpy as np
import boto3
from io import BytesIO
from datetime import datetime

BUCKET      = os.environ['BUCKET_NAME']
S3_ENDPOINT = os.environ['S3_ENDPOINT']
AWS_KEY     = os.environ['AWS_ACCESS_KEY_ID']
AWS_SECRET  = os.environ['AWS_SECRET_ACCESS_KEY']

DATASET  = 'shuyangli94/food-com-recipes-and-user-interactions'
DATA_DIR = '/tmp/foodcom'
WEIGHT_MAP = {5: 1.0, 4: 0.7, 3: 0.0, 2: -0.5, 1: -1.0}

# 7 discovery categories — ordered so first match wins per recipe
CATEGORIES = {
    "Italian":    ["italian-american", "pasta", "pizza", "lasagna", "italian"],
    "American":   ["american", "southern-united-states", "comfort-food", "north-american"],
    "Indian":     ["indian", "south-asian", "middle-eastern"],
    "Chinese":    ["chinese", "japanese", "thai", "korean", "asian"],
    "Mexican":    ["mexican", "tex-mex", "latin-american", "southwestern-united-states"],
    "Vegetarian": ["vegetarian", "vegan", "healthy"],
    "Desserts":   ["desserts", "cookies-and-brownies", "cakes", "pies-and-tarts", "candy"],
}

def s3_client():
    return boto3.client('s3', endpoint_url=S3_ENDPOINT,
                        aws_access_key_id=AWS_KEY,
                        aws_secret_access_key=AWS_SECRET)

def upload(client, df, key):
    buf = BytesIO()
    df.to_parquet(buf, index=False)
    buf.seek(0)
    client.put_object(Bucket=BUCKET, Key=key, Body=buf.getvalue())
    print(f"  ✓ Uploaded {key}  ({len(df):,} rows)")

def already_ingested(client) -> bool:
    """Return True if all processed files already exist in MinIO."""
    keys = [
        'processed/recipes_clean.parquet',
        'processed/interactions_clean.parquet',
        'processed/discovery_recipes.parquet',
    ]
    try:
        for key in keys:
            client.head_object(Bucket=BUCKET, Key=key)
        return True
    except Exception:
        return False

def download():
    print("Downloading Food.com from Kaggle...")
    os.makedirs(DATA_DIR, exist_ok=True)
    subprocess.run(['kaggle', 'datasets', 'download',
                    '-d', DATASET, '-p', DATA_DIR, '--unzip'], check=True)
    print("  ✓ Download complete")

def parse_list(val):
    if isinstance(val, list):
        return val
    if isinstance(val, str):
        try:
            return ast.literal_eval(val)
        except Exception:
            return []
    return []

def assign_category(tags: list) -> str | None:
    tag_set = set(tags)
    for category, keywords in CATEGORIES.items():
        if any(kw in tag_set for kw in keywords):
            return category
    return None

def clean_recipes():
    print("Cleaning recipes...")
    df = pd.read_csv(
        f'{DATA_DIR}/RAW_recipes.csv',
        usecols=['id', 'name', 'description', 'tags', 'minutes',
                 'nutrition', 'steps', 'ingredients'],
    )
    df = df.dropna(subset=['id', 'name', 'tags'])
    df['tags']        = df['tags'].apply(parse_list)
    df['steps']       = df['steps'].apply(parse_list)
    df['ingredients'] = df['ingredients'].apply(parse_list)
    df['description'] = df['description'].fillna('')
    df['minutes']     = df['minutes'].clip(upper=480)
    df = df.rename(columns={'id': 'recipe_id'})
    df['recipe_id']   = df['recipe_id'].astype(str)
    print(f"  ✓ {len(df):,} recipes")
    return df

def make_discovery_corpus(recipes_df: pd.DataFrame) -> pd.DataFrame:
    """Filter to 7 categories, keep fields needed for the discovery feed."""
    print("Building discovery corpus (7 categories)...")
    df = recipes_df.copy()
    df['category'] = df['tags'].apply(assign_category)
    corpus = df.dropna(subset=['category']).copy()

    # Cap steps at 20 to keep parquet size reasonable
    corpus['steps'] = corpus['steps'].apply(lambda s: s[:20])

    corpus = corpus[['recipe_id', 'name', 'description', 'tags',
                     'category', 'ingredients', 'steps']].reset_index(drop=True)

    print(f"  ✓ {len(corpus):,} recipes across 7 categories")
    for cat, grp in corpus.groupby('category'):
        print(f"    {cat}: {len(grp):,}")
    return corpus

def clean_interactions():
    print("Cleaning interactions...")
    df = pd.read_csv(f'{DATA_DIR}/RAW_interactions.csv',
                     usecols=['user_id', 'recipe_id', 'date', 'rating'])
    df = df.dropna()
    df['weight']    = df['rating'].map(WEIGHT_MAP)
    df              = df[df['weight'] != 0.0]
    df['recipe_id'] = df['recipe_id'].astype(int).astype(str)
    df['user_id']   = df['user_id'].astype(int).astype(str)
    df              = df.sort_values('date')
    print(f"  ✓ {len(df):,} interactions")
    return df

def main():
    client = s3_client()
    force  = os.environ.get('FORCE_INGEST', '').lower() in ('1', 'true', 'yes')

    if not force and already_ingested(client):
        print("✓ All processed files already exist in MinIO — skipping Kaggle download.")
        print("  Set FORCE_INGEST=1 to re-download and reprocess.")
        return

    download()
    recipes      = clean_recipes()
    interactions = clean_interactions()
    discovery    = make_discovery_corpus(recipes)

    upload(client, recipes,      'processed/recipes_clean.parquet')
    upload(client, interactions, 'processed/interactions_clean.parquet')
    upload(client, discovery,    'processed/discovery_recipes.parquet')

    print("\n✅ Ingestion complete!")

if __name__ == '__main__':
    main()
