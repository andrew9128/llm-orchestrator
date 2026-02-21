import asyncio
import aiohttp
import time
import random

# Конфигурация
URL = "http://localhost:8000/v1/chat/completions"
MODEL = "/home/yadrolab/llm_models/QVikhr-3-8B-Instruction"
CONCURRENT_USERS = 50  # Имитация 50 пользователей одновременно
MAX_CONTEXT_TEST = 18000 # Запрос больше, чем лимит 16k

async def send_request(session, user_id, prompt_len):
    # Генерируем "длинный" бессмысленный текст
    prompt = "Привет! " + ("бла " * prompt_len)
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 100,
        "stream": False
    }
    
    start_time = time.time()
    try:
        async with session.post(URL, json=payload) as resp:
            status = resp.status
            data = await resp.json()
            end_time = time.time()
            
            if status == 200:
                print(f"👤 User {user_id:02d}: ✅ OK ({end_time - start_time:.2f}s)")
            elif status == 400:
                print(f"👤 User {user_id:02d}: 🛡️ Защита сработала (400 Bad Request - слишком длинный текст)")
            else:
                print(f"👤 User {user_id:02d}: ❌ Ошибка {status}")
    except Exception as e:
        print(f"👤 User {user_id:02d}: 🔥 CRASH - {e}")

async def main():
    async with aiohttp.ClientSession() as session:
        print(f"🚀 Запуск теста: {CONCURRENT_USERS} пользователей одновременно...")
        
        # 1. ТЕСТ НА ПЕРЕПОЛНЕНИЕ КОНТЕКСТА (один очень длинный запрос)
        print("\n--- Тест 1: Запрос превышающий лимит (16000) ---")
        await send_request(session, 0, 17000)

        # 2. ТЕСТ НА ОЧЕРЕДЬ (много средних запросов)
        print(f"\n--- Тест 2: Очередь из {CONCURRENT_USERS} пользователей ---")
        tasks = []
        for i in range(1, CONCURRENT_USERS + 1):
            # Средняя длина 500 слов (~700 токенов)
            tasks.append(send_request(session, i, random.randint(1000, 5000)))
        
        await asyncio.gather(*tasks)

if __name__ == "__main__":
    asyncio.run(main())
