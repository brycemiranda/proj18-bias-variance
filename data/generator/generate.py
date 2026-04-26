#!/usr/bin/env python3
import os, time, random
import requests
import psycopg2

FEATURE_URL = os.environ.get('FEATURE_SERVICE_URL', 'http://feature_service:8000')
PG_HOST = os.environ.get('POSTGRES_HOST', 'postgres')
PG_USER = os.environ['POSTGRES_USER']
PG_PASS = os.environ['POSTGRES_PASSWORD']
PG_DB   = os.environ['POSTGRES_DB']

WEIGHT_MAP = {5: 1.0, 4: 0.7, 2: -0.5, 1: -1.0}

RECIPES = [
    {"recipe_id":"m001","name":"Spaghetti Carbonara",
     "tags":["italian","pasta","30-minutes-or-less"],"minutes":30,"calories":480},
    {"recipe_id":"m002","name":"Chicken Tikka Masala",
     "tags":["indian","chicken","spicy"],"minutes":50,"calories":420},
    {"recipe_id":"m003","name":"Avocado Toast",
     "tags":["vegetarian","healthy","15-minutes-or-less"],"minutes":10,"calories":280},
    {"recipe_id":"m004","name":"Beef Tacos",
     "tags":["mexican","beef","30-minutes-or-less"],"minutes":25,"calories":380},
    {"recipe_id":"m005","name":"Lentil Soup",
     "tags":["vegetarian","healthy","soup"],"minutes":45,"calories":220},
    {"recipe_id":"m006","name":"Banana Pancakes",
     "tags":["breakfast","sweet","vegetarian"],"minutes":20,"calories":350},
    {"recipe_id":"m007","name":"Grilled Salmon",
     "tags":["seafood","healthy","low-calorie"],"minutes":20,"calories":310},
    {"recipe_id":"m008","name":"Margherita Pizza",
     "tags":["italian","vegetarian"],"minutes":40,"calories":510},
]

USERS = [f"user_{i:04d}" for i in range(1, 21)]

def pg():
    return psycopg2.connect(host=PG_HOST, user=PG_USER,
                            password=PG_PASS, dbname=PG_DB)

def log_event(user_id, recipe_id, event_type, rating=None, weight=0.0):
    conn = pg(); cur = conn.cursor()
    cur.execute("""INSERT INTO mealie_events
                   (user_id, recipe_id, event_type, rating, weight)
                   VALUES (%s,%s,%s,%s,%s)""",
                (user_id, recipe_id, event_type, rating, weight))
    conn.commit(); cur.close(); conn.close()

def simulate_session(user_id):
    library = random.sample(RECIPES, random.randint(3, 6))
    try:
        resp = requests.post(f"{FEATURE_URL}/features",
                             json={"user_id": user_id,
                                   "library_recipes": library,
                                   "top_n": 5}, timeout=5)
        resp.raise_for_status()
    except Exception as e:
        print(f"  Feature service error: {e}"); return

    recipe     = random.choice(library)
    event_type = random.choices(['rating','save','dismiss'],
                                weights=[0.5, 0.3, 0.2])[0]

    if event_type == 'rating':
        rating = random.choice([1, 2, 4, 5])
        weight = WEIGHT_MAP[rating]
        log_event(user_id, recipe['recipe_id'], event_type, rating, weight)
        print(f"  [{user_id}] rated '{recipe['name']}' {rating}★ (w={weight})")
    elif event_type == 'save':
        log_event(user_id, recipe['recipe_id'], event_type, weight=0.4)
        print(f"  [{user_id}] saved '{recipe['name']}'")
    else:
        log_event(user_id, recipe['recipe_id'], event_type, weight=-0.3)
        print(f"  [{user_id}] dismissed '{recipe['name']}'")

def main():
    print("=== Mealie Data Generator ===")
    for _ in range(15):
        try:
            if requests.get(f"{FEATURE_URL}/health", timeout=3).ok:
                print("Feature service ready ✓\n"); break
        except:
            print("Waiting for feature service..."); time.sleep(3)

    count = 0
    while True:
        user_id = random.choice(USERS)
        print(f"\nSession #{count+1} | user={user_id}")
        simulate_session(user_id)
        count += 1
        time.sleep(random.uniform(2, 8))

if __name__ == '__main__':
    main()
