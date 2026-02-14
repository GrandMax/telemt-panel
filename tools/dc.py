from telethon import TelegramClient
from telethon.tl.functions.help import GetConfigRequest
import asyncio

api_id = ''
api_hash = ''

async def get_all_servers():
    print("🔄 Подключаемся к Telegram...")
    client = TelegramClient('session', api_id, api_hash)
    
    await client.start()
    print("✅ Подключение установлено!\n")
    
    print("📡 Запрашиваем конфигурацию серверов...")
    config = await client(GetConfigRequest())
    
    print(f"📊 Получено серверов: {len(config.dc_options)}\n")
    print("="*80)
    
    # Группируем серверы по DC ID
    dc_groups = {}
    for dc in config.dc_options:
        if dc.id not in dc_groups:
            dc_groups[dc.id] = []
        dc_groups[dc.id].append(dc)
    
    # Выводим все серверы, сгруппированные по DC
    for dc_id in sorted(dc_groups.keys()):
        servers = dc_groups[dc_id]
        print(f"\n🌐 DATACENTER {dc_id} ({len(servers)} серверов)")
        print("-" * 80)
        
        for dc in servers:
            # Собираем флаги
            flags = []
            if dc.ipv6:
                flags.append("IPv6")
            if dc.media_only:
                flags.append("🎬 MEDIA-ONLY")
            if dc.cdn:
                flags.append("📦 CDN")
            if dc.tcpo_only:
                flags.append("🔒 TCPO")
            if dc.static:
                flags.append("📌 STATIC")
            
            flags_str = f" [{', '.join(flags)}]" if flags else " [STANDARD]"
            
            # Форматируем IP (выравниваем для читаемости)
            ip_display = f"{dc.ip_address:45}"
            
            print(f"  {ip_display}:{dc.port:5}{flags_str}")
    
    # Статистика
    print("\n" + "="*80)
    print("📈 СТАТИСТИКА:")
    print("="*80)
    
    total = len(config.dc_options)
    ipv4_count = sum(1 for dc in config.dc_options if not dc.ipv6)
    ipv6_count = sum(1 for dc in config.dc_options if dc.ipv6)
    media_count = sum(1 for dc in config.dc_options if dc.media_only)
    cdn_count = sum(1 for dc in config.dc_options if dc.cdn)
    tcpo_count = sum(1 for dc in config.dc_options if dc.tcpo_only)
    static_count = sum(1 for dc in config.dc_options if dc.static)
    
    print(f"  Всего серверов:      {total}")
    print(f"  IPv4 серверы:        {ipv4_count}")
    print(f"  IPv6 серверы:        {ipv6_count}")
    print(f"  Media-only:          {media_count}")
    print(f"  CDN серверы:         {cdn_count}")
    print(f"  TCPO-only:           {tcpo_count}")
    print(f"  Static:              {static_count}")
    
    # Дополнительная информация из config
    print("\n" + "="*80)
    print("ℹ️  ДОПОЛНИТЕЛЬНАЯ ИНФОРМАЦИЯ:")
    print("="*80)
    print(f"  Дата конфигурации:   {config.date}")
    print(f"  Expires:             {config.expires}")
    print(f"  Test mode:           {config.test_mode}")
    print(f"  This DC:             {config.this_dc}")
    
    # Сохраняем в файл
    print("\n💾 Сохраняем результаты в файл telegram_servers.txt...")
    with open('telegram_servers.txt', 'w', encoding='utf-8') as f:
        f.write("TELEGRAM DATACENTER SERVERS\n")
        f.write("="*80 + "\n\n")
        
        for dc_id in sorted(dc_groups.keys()):
            servers = dc_groups[dc_id]
            f.write(f"\nDATACENTER {dc_id} ({len(servers)} servers)\n")
            f.write("-" * 80 + "\n")
            
            for dc in servers:
                flags = []
                if dc.ipv6:
                    flags.append("IPv6")
                if dc.media_only:
                    flags.append("MEDIA-ONLY")
                if dc.cdn:
                    flags.append("CDN")
                if dc.tcpo_only:
                    flags.append("TCPO")
                if dc.static:
                    flags.append("STATIC")
                
                flags_str = f" [{', '.join(flags)}]" if flags else " [STANDARD]"
                f.write(f"  {dc.ip_address}:{dc.port}{flags_str}\n")
        
        f.write(f"\n\nTotal servers: {total}\n")
        f.write(f"Generated: {config.date}\n")
    
    print("✅ Результаты сохранены в telegram_servers.txt")
    
    await client.disconnect()
    print("\n👋 Отключились от Telegram")

if __name__ == '__main__':
    asyncio.run(get_all_servers())