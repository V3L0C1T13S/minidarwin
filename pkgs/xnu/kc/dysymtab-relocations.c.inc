/* SPDX-License-Identifier: MIT
 * MH_KEXT_BUNDLE uses image-relative relocation addresses in LC_DYSYMTAB.
 * The section-relocation and dyld-opcode paths do not visit these tables.
 */
  if (dysymcmd && mv.cputype == CPU_TYPE_X86_64) {
    for (unsigned external = 0; external < 2; external++) {
      uint32_t off = external ? dysymcmd->extreloff : dysymcmd->locreloff;
      uint32_t count = external ? dysymcmd->nextrel : dysymcmd->nlocrel;
      if ((uint64_t)off + (uint64_t)count * 8 > sl) {
        fprintf(stderr, "invalid kext dynamic relocation table\n");
        free(sec_refs); free(sym_addrs); free(buf); return -1;
      }
      for (uint32_t i = 0; i < count; i++) {
        struct relocation_info r;
        memcpy(&r, buf + off + (size_t)i * 8, sizeof(r));
        size_t width = (size_t)1 << r.r_length;
        uint8_t *loc = NULL;
        if (r.r_address < 0 || r.r_extern != external) goto bad_dynamic_reloc;
        for (uint32_t j = 0; j < nseginfo; j++) {
          uint64_t addr = (uint32_t)r.r_address;
          if (addr >= seginfo[j].vmaddr &&
              addr - seginfo[j].vmaddr + width <= seginfo[j].filesize) {
            uint64_t fileoff = seginfo[j].fileoff + addr - seginfo[j].vmaddr;
            if (fileoff + width > sl) goto bad_dynamic_reloc;
            loc = buf + fileoff;
            break;
          }
        }
        if (!loc) goto bad_dynamic_reloc;
        if (!external) {
          if (r.r_type != X86_64_RELOC_UNSIGNED || r.r_pcrel || r.r_length != 3)
            goto bad_dynamic_reloc;
          w64(loc, r64(loc) + load_vmaddr);
        } else {
          if (r.r_symbolnum >= nsyms || !sym_addrs[r.r_symbolnum])
            goto bad_dynamic_reloc;
          uint64_t target = sym_addrs[r.r_symbolnum];
          if (r.r_type == X86_64_RELOC_UNSIGNED && !r.r_pcrel && r.r_length == 3) {
            w64(loc, target + r64(loc));
          } else if (r.r_type == X86_64_RELOC_BRANCH && r.r_pcrel && r.r_length == 2) {
            int64_t value = (int64_t)target - (int64_t)(load_vmaddr + r.r_address + 4) + (int32_t)r32(loc);
            if (value < INT32_MIN || value > INT32_MAX) goto bad_dynamic_reloc;
            w32(loc, (uint32_t)(int32_t)value);
          } else {
            goto bad_dynamic_reloc;
          }
        }
        continue;
      bad_dynamic_reloc:
        fprintf(stderr, "unsupported or invalid kext dynamic relocation %u:%u\n", external, i);
        free(sec_refs); free(sym_addrs); free(buf); return -1;
      }
    }
  }
