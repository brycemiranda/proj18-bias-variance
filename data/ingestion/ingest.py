#!/usr/bin/env python3
import os, json, subprocess, ast
import pandas as pd
import numpy as np
import boto3
import psycopg2
from io import BytesIO
from datetime import datetime

BUCKET      = os.environ['BUCKET_NAME']
S3_ENDPOINT = os.environ['S3_ENDPOINT']
AWS_KEY     = os.environ['AWS_ACCESS_KEY_ID']
AWS_SECRET  = os.environ['AWS_SECRET_ACCESS_KEY']
PG_HOST     = os.environ.get('POSTGRES_HOST', 'postgres')
PG_USER     = os.environ['POSTGRES_USER']
PG_PASS     = os.environ['POSTGRES_PASSWORD']
PG_DB       = os.environ['POSTGRES_DB']

DATASET     = 'shuyangli94/food-com-recipes-and-user-interactions'
DATA_DIR    = '/tmp/foodcom'
DIM         = 50

WEIGHT_MAP  = {5: 1.0, 4: 0.7, 3: 0.0, 2: -0.5, 1: -1.0}

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

def pg():
    return psycopg2.connect(host=PG_HOST, user=PG_USER,
                            password=PG_PASS, dbname=PG_DB)

def download():
    print("Downloading Food.com from Kaggle...")
    os.makedirs(DATA_DIR, exist_ok=True)
    subprocess.run(['kaggle', 'datasets', 'download',
                    '-d', DATASET, '-p', DATA_DIR, '--unzip'], check=True)
    print("  ✓ Download complete")

def clean_recipes():
    print("Cleaning recipes...")
    df = pd.read_csv(f'{DATA_DIR}/RAW_recipes.csv',
                     usecols=['id','name','tags','minutes','nutrition'])
    df = df.dropna()
    df['tags'] = df['tags'].apply(lambda x: ast.literal_eval(x)
                                   if isinstance(x, str) else [])
    df['minutes'] = df['minutes'].clip(upper=480)
    print(f"  ✓ {len(df):,} recipes")
    return df

def clean_interactions():
    print("Cleaning interactions...")
    df = pd.read_csv(f'{DATA_DIR}/RAW_interactions.csv',
                     usecols=['user_id','recipe_id','date','rating'])
    df = df.dropna()
    df['weight'] = df['rating'].map(WEIGHT_MAP)
    df = df[df['weight'] != 0.0]
    df = df.sort_values('date')
    print(f"  ✓ {len(df):,} interactions")
    return df

def make_synthetic(recipes_df, n=50_000):
    print(f"Generating {n:,} synthetic interactions...")
    np.random.seed(42)
    all_tags = list({t for tags in recipes_df['tags'] for t in tags})
    recipe_rows = recipes_df[['id','tags']].values.tolist()

    user_prefs = {
        f'synth_{u}': set(np.random.choice(all_tags,
                          size=np.random.randint(3,8), replace=False))
        for u in range(200)
    }

    rows = []
    for _ in range(n):
        uid = f'synth_{np.random.randint(0,200)}'
        rid, tags = recipe_rows[np.random.randint(0, len(recipe_rows))]
        overlap = len(set(tags) & user_prefs[uid])
        if   overlap >= 2: rating = int(np.random.choice([4,5], p=[0.4,0.6]))
        elif overlap == 1: rating = int(np.random.choice([3,4,5], p=[0.4,0.4,0.2]))
        else:              rating = int(np.random.choice([1,2,3], p=[0.3,0.4,0.3]))
        w = WEIGHT_MAP.get(rating, 0.0)
        if w != 0.0:
            rows.append({'user_id': uid, 'recipe_id': rid,
                         'rating': rating, 'weight': w,
                         'date': '2025-01-01'})

    df = pd.DataFrame(rows)
    print(f"  ✓ {len(df):,} synthetic interactions")
    return df

def seed_tag_vectors(recipes_df):
    print("Seeding placeholder tag vectors...")
    np.random.seed(0)
    all_tags = list({t for tags in recipes_df['tags'] for t in tags})
    conn = pg(); cur = conn.cursor()
    for tag in all_tags:
        vec = np.random.randn(DIM).tolist()
        cur.execute("""INSERT INTO tag_vectors (tag, vector)
                       VALUES (%s, %s) ON CONFLICT (tag) DO NOTHING""",
                    (tag, json.dumps(vec)))
    conn.commit(); cur.close(); conn.close()
    print(f"  ✓ {len(all_tags):,} tag vectors seeded")

def make_split(real_df, synth_df, version):
    print(f"Creating versioned split {version}...")
    combined = pd.concat([real_df, synth_df], ignore_index=True)
    combined['user_id'] = combined['user_id'].astype(str)   
    combined['recipe_id'] = combined['recipe_id'].astype(str)  
    combined = combined.sort_values('date')
    split = int(len(combined) * 0.8)
    train, val = combined.iloc[:split], combined.iloc[split:]
    print(f"  Train: {len(train):,}  |  Val: {len(val):,}")
    return train, val

def main():
    client  = s3_client()
    version = f"v1_{datetime.today().strftime('%Y-%m-%d')}"

    download()
    recipes      = clean_recipes()
    interactions = clean_interactions()
    synthetic    = make_synthetic(recipes)

    upload(client, recipes,      'processed/recipes_clean.parquet')
    upload(client, interactions, 'processed/interactions_clean.parquet')
    upload(client, synthetic,    'processed/synthetic_interactions.parquet')

    train, val = make_split(interactions, synthetic, version)
    upload(client, train, f'datasets/{version}/train.parquet')
    upload(client, val,   f'datasets/{version}/val.parquet')

    meta = {'version': version, 'train_rows': len(train),
            'val_rows': len(val), 'created_at': datetime.utcnow().isoformat()}
    client.put_object(Bucket=BUCKET, Key=f'datasets/{version}/meta.json',
                      Body=json.dumps(meta, indent=2))
    print("  ✓ Metadata written")

    seed_tag_vectors(recipes)
    print("\n✅ Ingestion pipeline complete!")

if __name__ == '__main__':
    main()
