curl "https://api.groq.com/openai/v1/chat/completions" \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${GROQ_API_KEY}" \
  -d '{
         "messages": [
           {
             "role": "system",
             "content": "this is the system prompt"
           },
           {
             "role": "user",
             "content": "this si the data"
           }
         ],
         "model": "moonshotai/kimi-k2-instruct-0905",
         "temperature": 0.6,
         "max_completion_tokens": 4096,
         "top_p": 1,
         "stream": true,
         "stop": null
       }'
  
