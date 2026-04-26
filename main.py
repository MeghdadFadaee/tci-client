#! /home/meghdad/PycharmProjects/tci-client/venv/bin/python3

import re
import os
import json
import dotenv
import requests
import subprocess
from pyfiglet import Figlet
from bs4 import BeautifulSoup

dotenv.load_dotenv()

BASE_URL = "https://internet.tci.ir"
CWD = os.getcwd()
ENV_PATH = os.path.join(CWD, ".env")

session = requests.Session()

# ------------------------
# Text Helpers
# ------------------------

TRANSLATIONS = {
    "میزان ترافیک رزرو شما": "Reserved Traffic",
    "گیگابایت": "GB",
    "مگابایت": "MB",
    ":": ": ",
}

PERSIAN_DIGITS = "۰۱۲۳۴۵۶۷۸۹"
ENGLISH_DIGITS = "0123456789"


def normalize_digits(text: str) -> str:
    return text.translate(str.maketrans(PERSIAN_DIGITS, ENGLISH_DIGITS))


def translate_text(text: str) -> str:
    for fa, en in TRANSLATIONS.items():
        text = text.replace(fa, en)
    return text


def clean_text(text: str) -> str:
    # remove weird unicode spaces
    text = re.sub(r"\s+", " ", text).strip()
    return text


def spaced(text: str):
    return " ".join(text)


def print_big(text: str):
    print("\033[92m")  # green
    print(Figlet(font="univers", width=150, justify="center").renderText(text))
    print("\033[0m")


# ------------------------
# Cookie Helpers
# ------------------------
def save_cookies():
    cookies_dict = session.cookies.get_dict()
    dotenv.set_key(ENV_PATH, "TCI_COOKIES", json.dumps(cookies_dict))


def load_cookies():
    cookies = os.getenv("TCI_COOKIES")
    if not cookies:
        return False

    try:
        cookies_dict = json.loads(cookies)
        session.cookies.update(cookies_dict)
        return True
    except:
        return False


# ------------------------
# Check if logged in
# ------------------------
def is_logged_in():
    res = session.get(f"{BASE_URL}/panel")
    return "logout" in res.text.lower() or "خروج" in res.text


# ------------------------
# Login flow
# ------------------------
def login():
    # print("Logging in...")

    res = session.get(f"{BASE_URL}/panel")
    soup = BeautifulSoup(res.text, "html.parser")

    form = soup.find("form")
    action_url = form["action"]

    captcha_url = soup.find("img", {"id": "loginCaptchaImage"})["src"]

    img_bytes = session.get(captcha_url).content

    captcha_path = f"{CWD}/captcha.jpg"
    with open(captcha_path, "wb") as f:
        f.write(img_bytes)

    try:
        subprocess.run(["kitty", "+kitten", "icat", captcha_path])
    except FileNotFoundError:
        # print("kitty icat not available")
        exit(1)

    captcha = input("Captcha: ")

    payload = {
        "username": os.getenv("TCI_USERNAME"),
        "password": os.getenv("TCI_PASSWORD"),
        "captcha": captcha,
        "redirect": "",
        "LoginFromWeb": "1"
    }

    res = session.post(action_url, data=payload)

    if "خروج" in res.text or "logout" in res.text.lower():
        # print("Login success ✅")
        save_cookies()
        return True
    else:
        # print("Login failed ❌")
        return False


# ------------------------
# Main logic
# ------------------------
def ensure_login():
    if load_cookies():
        # print("Loaded cookies")

        if is_logged_in():
            print("Session still valid ✅")
            return True
        else:
            print("Session expired ❌")

    return login()


# ------------------------
# Run
# ------------------------
if not ensure_login():
    exit(1)

# Fetch dashboard
dashboard_response = session.get(f"{BASE_URL}/panel")

with open(f"{CWD}/dashboard.html", "wb") as f:
    f.write(dashboard_response.content)

traffic_key = 'میزان ترافیک رزرو شما'

soup = BeautifulSoup(dashboard_response.text, "html.parser")
traffic_tag = soup.find(string=lambda text: text and traffic_key in text)

if traffic_tag:
    traffic_text = traffic_tag.parent.parent.get_text(strip=True)
    normalized = normalize_digits(traffic_text)
    translated = translate_text(normalized)
    cleaned = clean_text(translated)
    # print(cleaned)

    *_, traffic, unit = cleaned.split()
    print_big(f"{spaced(traffic)} {unit}")
else:
    print("Traffic info not found")
