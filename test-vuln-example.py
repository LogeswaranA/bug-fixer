#!/usr/bin/env python3
"""
Test file with intentional vulnerabilities for security-review skill validation.
DO NOT USE IN PRODUCTION.
"""

import os
import sqlite3
import hashlib

# CRITICAL: Hardcoded API key (SEC-001)
API_KEY = "sk-1234567890abcdef"
DB_PASSWORD = "admin123"

def login(username, password):
    """Login function with SQL injection vulnerability."""
    conn = sqlite3.connect('users.db')
    cursor = conn.cursor()

    # HIGH: SQL injection via string concatenation (SEC-002)
    query = f"SELECT * FROM users WHERE username='{username}' AND password='{password}'"
    cursor.execute(query)

    user = cursor.fetchone()
    conn.close()
    return user

def hash_password(password):
    """Password hashing with weak crypto."""
    # HIGH: Weak crypto - MD5 is cryptographically broken (SEC-003)
    return hashlib.md5(password.encode()).hexdigest()

def fetch_user_data(user_id):
    """Fetch user data with verbose error handling."""
    try:
        conn = sqlite3.connect('users.db')
        cursor = conn.cursor()
        cursor.execute(f"SELECT * FROM users WHERE id={user_id}")
        return cursor.fetchone()
    except Exception as e:
        # MEDIUM: Verbose error message exposing internals (SEC-004)
        print(f"Database error: {e}")
        print(f"Query was: SELECT * FROM users WHERE id={user_id}")
        raise

def process_payment(amount, card_number):
    """Process payment without input validation."""
    # MEDIUM: Missing input validation (SEC-005)
    # No check if amount is positive, no card number format validation
    print(f"Processing payment of ${amount} with card {card_number}")
    return True

if __name__ == "__main__":
    # Example usage
    user = login("admin", "password123")
    if user:
        print(f"Login successful: {user}")
